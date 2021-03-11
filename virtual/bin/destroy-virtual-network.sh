#!/bin/bash

# Copyright 2019, Bloomberg Finance L.P.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

# http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -xe

root_dir=$(git rev-parse --show-toplevel)
virtual_dir="${root_dir}/virtual"
network_dir="${virtual_dir}/network"

if [ "${VAGRANT_DEFAULT_PROVIDER}" == "libvirt" ] ; then
    export VAGRANT_VAGRANTFILE=Vagrantfile.libvirt
fi

(cd "${network_dir}"; vagrant destroy -f)


# TODO: Clobber only VMs and networks associated with this build
#   * build_hash=$( cd {$root_dir}/virtual/lib | tr -d '\n' | sha1sum )
#     * take the first 8 chars of the build hash
#   * assume 'virtual' if BCC_ENABLE_LIBVIRT_PREFIX is undef or not true
#   * grep virsh [list,net-list] for "^${hash}_" and clobber only that
#if [ "${VAGRANT_DEFAULT_PROVIDER}" == "libvirt" ] ; then
#    for NET in `virsh net-list | grep active | awk '{print $1}'`
#    do
#	virsh net-destroy ${NET}
#	virsh net-undefine ${NET}
#    done
#fi
