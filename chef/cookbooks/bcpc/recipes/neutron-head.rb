# Cookbook:: bcpc
# Recipe:: neutron-head
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

require 'ipaddress'

include_recipe 'bcpc::etcd3gw'
include_recipe 'bcpc::calico-apt'

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
  'dbname' => node['bcpc']['neutron']['db']['dbname'],
  'username' => config['neutron']['creds']['db']['username'],
  'password' => config['neutron']['creds']['db']['password'],
}

# hash used for openstack access
#
openstack = {
  'role' => node['bcpc']['keystone']['roles']['admin'],
  'project' => node['bcpc']['keystone']['service_project']['name'],
  'domain' => node['bcpc']['keystone']['service_project']['domain'],
  'username' => config['neutron']['creds']['os']['username'],
  'password' => config['neutron']['creds']['os']['password'],
}

# create neutron user starts
#
execute 'create the neutron user' do
  environment os_adminrc

  command <<-DOC
    openstack user create #{openstack['username']} \
      --domain #{openstack['domain']} \
      --password #{openstack['password']}
  DOC

  not_if <<-DOC
    openstack user show #{openstack['username']} \
      --domain #{openstack['domain']}
  DOC
end

execute 'add admin role to neutron user' do
  environment os_adminrc

  command <<-DOC
    openstack role add #{openstack['role']} \
       --user #{openstack['username']} --project #{openstack['project']}
  DOC

  not_if <<-DOC
    openstack role assignment list --names \
      --role #{openstack['role']} \
      --project #{openstack['project']} \
      --user #{openstack['username']} | grep #{openstack['username']}
  DOC
end
#
# create neutron user ends

ruby_block 'collect openstack service and endpoints list' do
  block do
    node.run_state['os_endpoints'] = openstack_endpoints()
    node.run_state['os_services'] = openstack_services()
  end
  action :run
end

# create network service and endpoints starts
#
begin
  type = 'network'
  service = node['bcpc']['catalog'][type]
  project = service['project']

  execute "create the #{project} #{type} service" do
    environment os_adminrc

    name = service['name']
    desc = service['description']

    command <<-DOC
      openstack service create \
        --name "#{name}" --description "#{desc}" #{type}
    DOC

    not_if { node.run_state['os_services'].include? type }
  end

  %w(admin internal public).each do |uri|
    url = generate_service_catalog_uri(service, uri)

    execute "create the #{project} #{type} #{uri} endpoint" do
      environment os_adminrc

      command <<-DOC
        openstack endpoint create \
          --region #{region} #{type} #{uri} '#{url}'
      DOC

      not_if { node.run_state['os_endpoints'].fetch(type, []).include? uri }
    end
  end
end
#
# create network service and endpoints ends

# neutron package installation and service definition starts
#
package 'neutron-server'

package 'calico-control' do
  action :upgrade
  notifies :restart, 'service[neutron-server]', :delayed
end

# install patches for both neutron and neutron-lib
# https://bugs.launchpad.net/neutron/+bug/1918145
cookbook_file '/usr/lib/python3/dist-packages/neutron/db/external_net_db.py' do
  source 'neutron/external_net_db.py'
  notifies :run, 'execute[py3compile-neutron]', :immediately
  notifies :restart, 'service[neutron-server]', :delayed
end

execute 'py3compile-neutron' do
  action :nothing
  command 'py3compile -p python3-neutron'
end

cookbook_file '/usr/lib/python3/dist-packages/neutron_lib/db/model_query.py' do
  source 'neutron/model_query.py'
  notifies :run, 'execute[py3compile-neutron-lib]', :immediately
  notifies :restart, 'service[neutron-server]', :delayed
end

execute 'py3compile-neutron-lib' do
  action :nothing
  command 'py3compile -p python3-neutron-lib'
end

# patch an outstanding python3 issue in etcd3gw
# we do this here and not in bcpc::etcd3gw so we can notify neutron-server
cookbook_file '/usr/local/lib/python3.6/dist-packages/etcd3gw/watch.py' do
  source 'etcd3gw/watch.py'
  notifies :run, 'execute[py3compile-etcd3gw-watch]', :immediately
  notifies :restart, 'service[neutron-server]', :delayed
end

execute 'py3compile-etcd3gw-watch' do
  action :nothing
  command 'py3compile /usr/local/lib/python3.6/dist-packages/etcd3gw/watch.py'
end

service 'neutron-server'

#
# neutron package installation and service definition ends

# add neutron to etcd so that it will be able to read the etcd ssl certs
group 'etcd' do
  action :modify
  members 'neutron'
  append true
end

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

# create/manage neutron database starts
#
file '/tmp/neutron-db.sql' do
  action :nothing
end

template '/tmp/neutron-db.sql' do
  source 'neutron/neutron-db.sql.erb'
  variables(
    db: database
  )
  notifies :run, 'execute[create neutron database]', :immediately
  not_if "
    user=#{mysqladmin['username']}
    db=#{database['dbname']}
    count=$(mysql -u ${user} ${db} -e 'show tables' | wc -l)
    [ $count -gt 0 ]
  ", environment: { 'MYSQL_PWD' => mysqladmin['password'] }
end

execute 'create neutron database' do
  action :nothing
  environment('MYSQL_PWD' => mysqladmin['password'])

  command "mysql -u #{mysqladmin['username']} < /tmp/neutron-db.sql"

  notifies :delete, 'file[/tmp/neutron-db.sql]', :immediately
  notifies :create, 'template[/etc/neutron/neutron.conf]', :immediately
  notifies :create, 'cookbook_file[/etc/neutron/plugins/ml2/ml2_conf.ini]',
           :immediately
  notifies :run, 'execute[neutron-db-manage upgrade heads]', :immediately
end

execute 'neutron-db-manage upgrade heads' do
  action :nothing
  command 'su -s /bin/sh -c "neutron-db-manage upgrade heads" neutron'
end
#
# create/manage neutron database ends

# configure neutron starts
#

template '/etc/neutron/neutron.conf' do
  source 'neutron/neutron.conf.erb'
  mode '0640'
  owner 'root'
  group 'neutron'

  variables(
    db: database,
    os: openstack,
    config: config,
    headnodes: headnodes(all: true),
    rmqnodes: rmqnodes(all: true)
  )
  notifies :restart, 'service[neutron-server]', :immediately
end

cookbook_file '/etc/neutron/plugins/ml2/ml2_conf.ini' do
  source 'neutron/neutron.ml2_conf.ini.erb'
  notifies :restart, 'service[neutron-server]', :immediately
end

cookbook_file '/etc/neutron/api-paste.ini' do
  source 'neutron/api-paste.ini'
  mode '0640'
  notifies :restart, 'service[neutron-server]', :immediately
end
# configure neutron ends

execute 'wait for neutron to come online' do
  environment os_adminrc
  retries 15
  command 'openstack network list'
end

ruby_block 'collect openstack network, subnet, and router list' do
  block do
    Chef::Resource::RubyBlock.send(:include, Chef::Mixin::ShellOut)
    os_command = 'openstack network list --format json'
    os_command_out = shell_out(os_command, env: os_adminrc)
    networks_list = JSON.parse(os_command_out.stdout)

    os_command = 'openstack subnet list --format json'
    os_command_out = shell_out(os_command, env: os_adminrc)
    subnets_list = JSON.parse(os_command_out.stdout)

    os_command = 'openstack router list --format json'
    os_command_out = shell_out(os_command, env: os_adminrc)
    routers_list = JSON.parse(os_command_out.stdout)

    node.run_state['os_networks'] = networks_list.map { |n| n['Name'] }
    node.run_state['os_subnets'] = subnets_list.map { |s| s['Subnet'] }
    node.run_state['os_routers'] = routers_list.map { |r| r['Name'] }
  end
  action :run
end

# create networks starts
node['bcpc']['neutron']['networks'].each do |network|
  fixed_network = network['name']
  default_network_mtu = node['bcpc']['neutron']['network']['default_network_mtu']

  raise "#{fixed_network}: no subnets defined" unless network.key?('fixed')

  # build the create network command line options
  network_create_opts = [
    '--provider-network-type local',
    "--mtu #{default_network_mtu}",
  ]

  # networks are shared by default unless explicitly set to false in the config
  if network.fetch('shared', true)
    network_create_opts.push('--share')
  else
    network_create_opts.push('--no-share')
  end

  # create fixed network
  execute "create the #{fixed_network} network" do
    environment os_adminrc

    command <<-DOC
      openstack network create \
        #{fixed_network} \
        #{network_create_opts.join(' ')}
    DOC

    not_if { node.run_state['os_networks'].include? fixed_network }
  end

  # create fixed subnets
  network['fixed'].fetch('subnets', []).each do |subnet|
    allocation = IPAddress(subnet['allocation'])
    cidr = "#{allocation.network.address}/#{allocation.prefix}"
    subnet_name = "#{fixed_network}-fixed-#{cidr}"

    execute "create the #{fixed_network} network #{subnet_name} subnet" do
      environment os_adminrc

      # convert nameservers list into repeated --dns-nameserver arguments
      nameservers = node['bcpc']['neutron']['network']['nameservers']
      nameservers = nameservers.map do |n|
        "--dns-nameserver #{n}"
      end
      nameservers = nameservers.join(' ')

      command <<-DOC
        openstack subnet create #{subnet_name} \
          #{nameservers} \
          --network #{fixed_network} \
          --subnet-range #{cidr}
      DOC

      not_if { node.run_state['os_subnets'].include? cidr }
    end
  end

  next unless network.key?('float')

  # create float network
  float_network = "#{network['name']}-float"

  execute "create the #{float_network} network" do
    environment os_adminrc

    command <<-DOC
      # create the floating network and capture the output in shell format
      # so we can easily get the network id from the prefixed 'fn_' shell
      # variables
      new_fn_output=$(openstack network create #{float_network} \
                        --external \
                        --format shell \
			--mtu #{default_network_mtu} \
                        --prefix 'fn_')

      # evaluate the shell output so we can access the values
      eval ${new_fn_output}

      # get the rbac id for the newly created floating network
      fn_rbac_id=$(openstack network rbac list \
                     --type network \
                     --action access_as_external \
                     --format value \
                   | grep ${fn_id} | awk '{print $1}')

      # use the fn_rbac_id to set the rbac target-project to the admin
      # project so that only admins can see these networks
      openstack network rbac set ${fn_rbac_id} --target-project admin
    DOC

    not_if { node.run_state['os_networks'].include? float_network }
  end

  # create float subnets
  network['float'].fetch('subnets', []).each do |subnet|
    allocation = IPAddress(subnet['allocation'])
    cidr = "#{allocation.network.address}/#{allocation.prefix}"
    subnet_name = "#{float_network}-#{cidr}"

    execute "create the #{float_network} network #{subnet_name} subnet" do
      environment os_adminrc

      command <<-DOC
        openstack subnet create #{subnet_name} \
          --network #{float_network} --subnet-range #{cidr}
      DOC

      not_if { node.run_state['os_subnets'].include? cidr }
    end
  end

  # create router
  router_name = fixed_network

  execute "create the #{fixed_network} network router (#{router_name})" do
    environment os_adminrc

    command <<-DOC
      openstack router create #{router_name}
    DOC

    not_if { node.run_state['os_routers'].include? router_name }
  end

  # add subnets to router
  bash 'add subnets to router' do
    environment os_adminrc
    code <<-EOH
      set -e

      subnets=$(openstack subnet list --network #{fixed_network} -c ID -f value)
      ifaces=$(openstack router show #{router_name} -f json | jq -r .interfaces_info)

      for subnet_id in ${subnets}; do
        exists=$(echo $ifaces | jq --arg SUBNET_ID "$subnet_id" '.[] | select(.subnet_id == $SUBNET_ID)')

        if [ ${#exists} -eq 0 ]; then
          openstack router add subnet #{router_name} ${subnet_id}
        fi
      done
    EOH
  end

  # set router external gateway
  bash 'set external gateway for router' do
    environment os_adminrc

    code <<-EOH
      set -e

      router=$(openstack router show #{router_name} -f json)
      gateway=$(echo ${router} | jq -r .external_gateway_info)

      if [ "${gateway}" = "null" ]; then
        openstack router set #{router_name} --external-gateway #{float_network}
      fi
    EOH
  end
end
# create networks ends

bash 'update admin default security group' do
  environment os_adminrc

  code <<-DOC
    admin_project=#{node['bcpc']['openstack']['admin']['project']}
    id=$(openstack project show ${admin_project} -f value -c id)

    sec_groups=$(openstack security group list --project ${id} -f json)
    sec_id=$(echo ${sec_groups} | jq -r '.[] | select(.Name == "default") .ID')

    for ethertype in IPv4 IPv6; do

      # allow icmp
      if ! openstack security group rule list ${sec_id} \
            --protocol icmp \
            --long -c Ethertype -f value | grep -q ${ethertype}; then

        openstack security group rule create ${sec_id} \
          --protocol icmp \
          --ethertype ${ethertype}

      fi

      # allow ssh, http and https
      for port_range in 22:22 80:80 443:443; do
        if ! openstack security group rule list ${sec_id} \
              --protocol tcp --long \
              -c "Port Range" -c "Ethertype" \
              -f value | grep "${port_range}" | grep "${ethertype}"; then

          [[ ${ethertype} = 'IPv4' ]] && \
            remote_ip='0.0.0.0/0' || remote_ip='::/0'

          openstack security group rule create ${sec_id} \
            --protocol tcp \
            --dst-port ${port_range} \
            --remote-ip ${remote_ip} \
            --ethertype ${ethertype}
        fi
      done

      # allow UDP port range used by traceroute(1)
      for port_range in 33434:33464; do
        if ! openstack security group rule list ${sec_id} \
              --protocol udp --long \
              -c "Port Range" -c "Ethertype" \
              -f value | grep "${port_range}" | grep "${ethertype}"; then

          [[ ${ethertype} = 'IPv4' ]] && \
            remote_ip='0.0.0.0/0' || remote_ip='::/0'

          openstack security group rule create ${sec_id} \
            --protocol udp \
            --dst-port ${port_range} \
            --remote-ip ${remote_ip} \
            --ethertype ${ethertype}
        fi
      done

    done
  DOC
end
