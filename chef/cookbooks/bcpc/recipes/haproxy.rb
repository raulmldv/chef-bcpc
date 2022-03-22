# Cookbook:: bcpc
# Recipe:: haproxy
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

repo = node['bcpc']['haproxy']['repo']
codename = node['lsb']['codename']

apt_repository 'haproxy' do
  uri repo['url']
  distribution codename
  components ['main']
  key repo['key']
  only_if { repo['enabled'] }
end

region = node['bcpc']['cloud']['region']
config = data_bag_item(region, 'config')

package 'haproxy' do
  action :upgrade
end
service 'haproxy'

directory '/etc/haproxy/haproxy.d' do
  action :create
end

cookbook_file '/etc/default/haproxy' do
  source 'haproxy/default'
  notifies :restart, 'service[haproxy]', :immediately
end

begin

  certs = []
  certs.push(Base64.decode64(config['ssl']['crt']))

  if config['ssl']['intermediate']
    certs.push(Base64.decode64(config['ssl']['intermediate']))
  end

  certs.push(Base64.decode64(config['ssl']['key']))

  template '/etc/haproxy/haproxy.pem' do
    source 'haproxy/haproxy.pem.erb'
    mode '600'

    variables(
      certs: certs
    )

    notifies :restart, 'service[haproxy]', :delayed
  end

end

template '/etc/haproxy/haproxy.cfg' do
  source 'haproxy/haproxy.cfg.erb'
  variables(
    user: config['haproxy'],
    headnodes: headnodes(all: true),
    rmqnodes: rmqnodes(all: true),
    vip: node['bcpc']['cloud']['vip']
  )
  notifies :reload, 'service[haproxy]', :immediately
end

template '/etc/haproxy/errors/429.http' do
  source 'haproxy/429.http.erb'
  notifies :reload, 'service[haproxy]', :immediately
end

directory '/etc/haproxy/acls' do
  action :create
end

template '/etc/haproxy/acls/qos-exempt.acl' do
  source 'haproxy/qos-exempt.acl.erb'
  variables(
    aggregate_cidr: node['bcpc']['networking']['networks']['primary']['aggregate-cidr']
  )
  notifies :reload, 'service[haproxy]', :immediately
end
