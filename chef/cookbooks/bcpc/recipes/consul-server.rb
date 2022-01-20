# Cookbook:: bcpc-consul-server
# Recipe:: consul
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

include_recipe 'bcpc::consul-package'

region = node['bcpc']['cloud']['region']
config = data_bag_item(region, 'config')

service 'consul'

directory '/usr/local/bcpc/bin' do
  recursive true
end

begin
  config = node['bcpc']['consul']['config']
  config = config.merge('bootstrap' => true)
  file "#{node['bcpc']['consul']['conf_dir']}/config.json" do
    content JSON.pretty_generate(config)
    notifies :restart, 'service[consul]', :immediately
  end
end

execute 'wait for consul leader' do
  retries 10
  command <<-DOC
    curl -q http://localhost:8500/v1/status/leader | grep -q \:8300
  DOC
end
