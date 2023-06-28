# Cookbook:: bcpc
# Recipe:: ceph-packages
#
# Copyright:: 2023 Bloomberg Finance L.P.
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

apt_repository 'ceph' do
  uri node['bcpc']['ceph']['repo']['url']
  components ['main']
  key 'ceph/release.key'
  only_if { node['bcpc']['ceph']['repo']['enabled'] }
end

package 'ceph'

if storagenode?
  package 'ceph-volume' do
    ignore_failure true
  end
end

# ceph-deploy has been deprecated and is unavailable in Jammy
# We are really due to move off of ceph-deploy, but for now...
package 'ceph-deploy' do
  package_name 'ceph-deploy'
  action :remove
end

package 'python3-execnet'
package 'python3-setuptools'

target = node['bcpc']['ceph']['ceph-deploy']['remote_file']['file']
ceph_deploy = File.basename("#{target}", '.tar.gz')
save_path = "#{Chef::Config[:file_cache_path]}/#{target}"
web_server_url = node['bcpc']['web_server']['url']

remote_file save_path do
  source "#{web_server_url}/#{target}"
  checksum node['bcpc']['ceph']['ceph-deploy']['remote_file']['checksum']
  notifies :run, 'bash[install ceph-deploy]', :immediately
end

bash 'install ceph-deploy' do
  action :nothing
  cwd Chef::Config[:file_cache_path]
  code <<-EOH
    tar -xzf #{target}
    python3 -m pip install ./#{ceph_deploy}
  EOH
  retries 5
  retry_delay 2
end
