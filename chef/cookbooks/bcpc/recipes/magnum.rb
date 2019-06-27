# Cookbook:: bcpc
# Recipe:: magnum
#
# Copyright:: 2019 Bloomberg Finance L.P.
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

return unless node['bcpc']['heat']['enabled'] && node['bcpc']['magnum']['enabled']

region = node['bcpc']['cloud']['region']
config = data_bag_item(region, 'config')

mysqladmin = mysqladmin()

database = {
  'host' => node['bcpc']['mysql']['host'],
  'dbname' => node['bcpc']['magnum']['db']['dbname'],
  'username' => config['magnum']['creds']['db']['username'],
  'password' => config['magnum']['creds']['db']['password'],
}

# magnum openstack access
openstack = {
  'role' => node['bcpc']['keystone']['roles']['admin'],
  'project' => node['bcpc']['keystone']['service_project']['name'],
  'domain' => node['bcpc']['keystone']['service_project']['domain'],
  'username' => config['magnum']['creds']['os']['username'],
  'password' => config['magnum']['creds']['os']['password'],
}

# create magnum service user
execute 'create openstack magnum user' do
  environment os_adminrc

  command <<-DOC
    openstack user create #{openstack['username']} \
      --domain #{openstack['domain']} \
      --password #{openstack['password']}
  DOC

  not_if "
    openstack user show #{openstack['username']} \
      --domain #{openstack['domain']}
  "
end

execute "add #{openstack['role']} role to #{openstack['username']} user" do
  environment os_adminrc

  command <<-DOC
    openstack role add #{openstack['role']} \
      --project #{openstack['project']} \
      --user #{openstack['username']}
  DOC

  not_if <<-DOC
    openstack role assignment list \
      --names \
      --role #{openstack['role']} \
      --project #{openstack['project']} \
      --user #{openstack['username']} | grep #{openstack['username']}
  DOC
end

# create magnum domain
execute 'create magnum domain' do
  environment os_adminrc
  desc = 'Owns users and projects created by magnum'
  command <<-DOC
    openstack domain create --description "#{desc}" magnum
  DOC
  not_if 'openstack domain show magnum'
end

# create magnum_domain_admin user
execute 'create magnum_domain_admin user' do
  environment os_adminrc
  command <<-DOC
    openstack user create magnum_domain_admin \
      --domain magnum \
      --password #{openstack['password']}
  DOC
  not_if 'openstack user show magnum_domain_admin --domain magnum'
end

# add admin role to magnum_domain_admin user in magnum domain
execute 'add admin role to magnum_domain_admin user in magnum domain' do
  environment os_adminrc
  command <<-DOC
   openstack role add --domain magnum --user-domain magnum \
     --user magnum_domain_admin admin
  DOC

  not_if <<-DOC
    openstack role assignment list \
      --names \
      --role admin \
      --domain magnum \
      --user-domain magnum \
      --user magnum_domain_admin | grep magnum_domain_admin
  DOC
end

# create magnum service and endpoints
begin
  type = 'container-infra'
  service = node['bcpc']['catalog'][type]
  name = service['name']

  execute "create the #{name} service" do
    environment os_adminrc
    desc = service['description']
    command <<-DOC
      openstack service create --name "#{name}" --description "#{desc}" #{type}
    DOC
    not_if "openstack service list | grep #{type}"
  end

  %w(admin internal public).each do |uri|
    url = generate_service_catalog_uri(service, uri)
    execute "create the #{name} #{type} #{uri} endpoint" do
      environment os_adminrc
      command <<-DOC
        openstack endpoint create --region #{region} #{type} #{uri} '#{url}'
      DOC
      not_if "openstack endpoint list | grep #{type} | grep #{uri}"
    end
  end
end

# install haproxy fragment
template '/etc/haproxy/haproxy.d/magnum.cfg' do
  source 'magnum/haproxy.cfg.erb'
  variables(
    headnodes: headnodes(all: true),
    vip: node['bcpc']['cloud']['vip']
  )
  notifies :restart, 'service[haproxy-magnum]', :immediately
end

# magnum packages installation and service definitions
magnum_packages = %w(magnum-api magnum-conductor python-magnumclient)
package magnum_packages

service 'magnum-conductor'

service 'magnum-api' do
  action [:stop, :disable]
end

service 'magnum-api-apache2' do
  service_name 'apache2'
end

service 'haproxy-magnum' do
  service_name 'haproxy'
end

# configure magnum-api service
template '/etc/apache2/sites-available/magnum-api.conf' do
  source 'magnum/magnum-api.conf.erb'
  variables(
    processes: node['bcpc']['magnum']['api_workers']
  )
  notifies :run, 'execute[enable magnum-api]', :immediately
  notifies :create, 'template[/tmp/magnum-create-db.sql]', :immediately
  notifies :restart, 'service[magnum-api-apache2]', :immediately
end

execute 'enable magnum-api' do
  command 'a2ensite magnum-api'
  not_if 'a2query -s magnum-api'
end

# create policy.d dir for policy overrides
directory '/etc/magnum/policy.d' do
  action :create
end

# create/manage magnum database starts
file '/tmp/magnum-create-db.sql' do
  action :nothing
end

template '/tmp/magnum-create-db.sql' do
  source 'magnum/magnum-create-db.sql.erb'
  variables(
    db: database
  )
  notifies :run, 'execute[create magnum database]', :immediately
  not_if "
    user=#{mysqladmin['username']}
    db=#{database['dbname']}
    count=$(mysql -u ${user} ${db} -e 'show tables' | wc -l)
    [ $count -gt 0 ]
  ", environment: { 'MYSQL_PWD' => mysqladmin['password'] }
end

execute 'create magnum database' do
  action :nothing
  environment('MYSQL_PWD' => mysqladmin['password'])
  command "mysql -u #{mysqladmin['username']} < /tmp/magnum-create-db.sql"
  notifies :delete, 'file[/tmp/magnum-create-db.sql]', :immediately
  notifies :create, 'cookbook_file[/etc/magnum/api-paste.ini]', :immediately
  notifies :run, 'execute[magnum-db-manage upgrade]', :immediately
  notifies :restart, 'service[magnum-conductor]', :immediately
end

execute 'magnum-db-manage upgrade' do
  action :nothing
  command "su -s /bin/sh -c 'magnum-db-manage upgrade' magnum"
end

# configure magnum
cookbook_file '/etc/magnum/api-paste.ini' do
  source 'magnum/api-paste.ini'
  mode '0640'
  notifies :restart, 'service[magnum-api-apache2]', :immediately
  notifies :create, 'template[/etc/magnum/magnum.conf]', :immediately
end

template '/etc/magnum/magnum.conf' do
  source 'magnum/magnum.conf.erb'
  variables(
    db: database,
    os: openstack,
    config: config,
    is_headnode: headnode?,
    headnodes: headnodes(all: true),
    vip: node['bcpc']['cloud']['vip']
  )
  notifies :run, 'execute[magnum-db-manage upgrade]', :immediately
  notifies :restart, 'service[magnum-api-apache2]', :immediately
  notifies :restart, 'service[magnum-conductor]', :immediately
end

execute 'wait for magnum api to become available' do
  environment os_adminrc
  retries 15
  command 'openstack coe service list'
end
