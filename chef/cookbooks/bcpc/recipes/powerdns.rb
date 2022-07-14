# Cookbook:: bcpc
# Recipe:: powerdns
#
# Copyright:: 2021 Bloomberg Finance L.P.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

pdns_attr = node['bcpc']['powerdns']

unless pdns_attr['enabled']
  service 'pdns' do
    action :stop
  end

  package %w(
    pdns-server
    pdns-backend-mysql
  ) do
    action :purge
  end

  file '/usr/local/sbin/catalog-zone-manage' do
    action :delete
  end

  directory '/usr/local/lib/catalog-zone' do
    action :delete
    recursive true
  end

  directory '/usr/local/etc/catalog-zone' do
    action :delete
    recursive true
  end

  execute 'delete pdns database' do
    environment('MYSQL_PWD' => mysqladmin['password'])
    command <<-EOF
      mysql -u #{mysqladmin['username']} -e \
        "DROP DATABASE IF EXISTS #{pdns_attr['db']['dbname']};"
    EOF
  end
end

return unless pdns_attr['enabled']

require 'ipaddress'

region = node['bcpc']['cloud']['region']
config = data_bag_item(region, 'config')

mysqladmin = mysqladmin()
psqladmin = psqladmin()
db_conn = db_conn()

# hash used for database creation and access
#
database = {
  'host' => db_conn['host'],
  'port' => db_conn['port'],
  'dbname' => node['bcpc']['powerdns']['db']['dbname'],
  'username' => config['powerdns']['creds']['db']['username'],
  'password' => config['powerdns']['creds']['db']['password'],
}

# Ensure the database user is present on ProxySQL
#
bcpc_proxysql_user "create #{database['username']} proxysql user" do
  user database
  psqladmin psqladmin
  only_if { node['bcpc']['proxysql']['enabled'] }
  notifies :run, 'bcpc_proxysql_reload[reload proxysql '\
    "#{database['username']}]", :immediately
end

bcpc_proxysql_reload "reload proxysql #{database['username']}" do
  psqladmin psqladmin
  action :nothing
end
# end ProxySQL user creation

# create/manage pdns database starts
#
file '/tmp/pdns-create-db.sql' do
  action :nothing
end

template '/tmp/pdns-create-db.sql' do
  source 'powerdns/pdns-create-db.sql.erb'
  variables(
    'db' => database
  )
  notifies :run, 'execute[create pdns database]', :immediately
  not_if "
    user=#{mysqladmin['username']}
    db=#{database['dbname']}
    count=$(mysql -u ${user} ${db} -e 'show tables' | wc -l)
    [ $count -gt 0 ]
  ", environment: { 'MYSQL_PWD' => mysqladmin['password'] }
end

execute 'create pdns database' do
  action :nothing
  environment('MYSQL_PWD' => mysqladmin['password'])

  command "mysql -u #{mysqladmin['username']} < /tmp/pdns-create-db.sql"

  notifies :delete, 'file[/tmp/pdns-create-db.sql]', :immediately
end

#
# create/manage pdns database ends
package %w(
  pdns-server
  pdns-backend-mysql
  python3-dnspython
  python3-jinja2
)
service 'pdns'

# remove default pdns.d directory
directory '/etc/powerdns/pdns.d' do
  action :delete
  recursive true
end

template '/etc/powerdns/pdns.conf' do
  source 'powerdns/pdns.conf.erb'
  variables(
    db: database,
    api_key: config['powerdns']['creds']['api']['key'],
    webserver_password: config['powerdns']['creds']['webserver']['password']
  )
  notifies :restart, 'service[pdns]', :immediately
end

# DNS forward zone creation/population
#
serial = Time.now.to_i
email = node['bcpc']['keystone']['admin']['email'].tr('@', '.')
networks = node['bcpc']['neutron']['networks'].dup

# expand subnet ip allocations

networks.each do |network|
  %w(fixed float).each do |type|
    network[type].fetch('subnets', []).each do |subnet|
      subnet['allocation'] = IPAddress(subnet['allocation'])
    end
  end
end

# create the forward zone for the cloud domain
begin
  zone = node['bcpc']['cloud']['domain']
  zone_file = "#{Chef::Config[:file_cache_path]}/#{zone}.zone"

  template zone_file do
    source 'powerdns/zone.erb'
    variables(
      email: email,
      serial: serial,
      networks: networks
    )
    not_if "pdnsutil list-all-zones | grep -w #{zone}"
  end

  execute 'load zone' do
    command <<-EOH
      pdnsutil load-zone #{zone} #{zone_file}
    EOH
    not_if "pdnsutil list-all-zones | grep -w #{zone}"
  end
end

# create the reverse zone for each subnet
begin
  networks.each do |network|
    %w(fixed float).each do |type|
      next unless network[type]['dns-zones']['create']

      network[type].fetch('subnets', []).each do |subnet|
        zones = cidr_to_reverse_zones(subnet['allocation'])

        zones.each do |z|
          domain = z['zone']
          zone_file = "#{Chef::Config[:file_cache_path]}/#{domain}.zone"

          template zone_file do
            source 'powerdns/reverse-zone.erb'
            variables(
              zone: z,
              email: email,
              serial: serial,
              fqdn_prefix: network[type]['dns-zones']['fqdn-prefix']
            )
            not_if "pdnsutil list-all-zones | grep -w #{domain}"
          end

          execute 'load reverse zone' do
            command <<-EOH
              pdnsutil load-zone #{domain} #{zone_file}
            EOH
            not_if "pdnsutil list-all-zones | grep -w #{domain}"
          end
        end
      end
    end
  end
end
