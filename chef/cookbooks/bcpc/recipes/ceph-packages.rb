# Cookbook:: bcpc
# Recipe:: ceph-packages
#
# Copyright:: 2022 Bloomberg Finance L.P.
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

package %w(
  ceph
  ceph-deploy
)

# workaround python3.8 deprecation of platform.linux_distribution.
# ceph-deploy has not been rewired to workaround this, so we do it here.
if platform?('ubuntu') && node['platform_version'] == '20.04'
  package 'python3-distro'

  cookbook_file '/usr/lib/python3/dist-packages/ceph_deploy/hosts/remotes.py' do
    source 'ceph/remotes.py'
    notifies :run, 'execute[py3compile-ceph-deploy]', :immediately
  end

  execute 'py3compile-ceph-deploy' do
    action :nothing
    command 'py3compile -p ceph-deploy'
  end
end
