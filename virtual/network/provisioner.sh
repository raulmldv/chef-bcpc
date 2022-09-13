#!/bin/bash

# Copyright 2022, Bloomberg Finance L.P.
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

# The on_edge_flag defines whether a router should be left "connected" to
# the outside such as running DHCP and adding a masquerade source NAT rule.

set -eux

on_edge_flag=0


on_edge() {
    [[ ${on_edge_flag} == 1 ]]
}

switch_config() {
    # enable IPv4 forwarding
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/90-bcpc.conf
    sysctl -qp /etc/sysctl.d/90-bcpc.conf

    if on_edge "${1}"; then
        # add masquerading source NAT rule on spines or super spines
        iptables -A POSTROUTING -j MASQUERADE -o eth0 -t nat
        touch /etc/iptables/rules.v4
        chmod 0640 /etc/iptables/rules.v4
        /sbin/iptables-save > /etc/iptables/rules.v4
    fi

    # configure BIRD
    cp "/vagrant/bird/${1}.conf" /etc/bird/bird.conf
    systemctl restart bird
}

base_config() {
    if [ "$(lsb_release -sc)" == "bionic" ]; then
        disabled_services=(rpcbind lxcfs snapd lxd iscsid)
    elif [ "$(lsb_release -sc)" == "focal" ]; then
        disabled_services=(multipathd.socket multipathd snapd.socket \
            snapd snapd.seeded udisks2)
    fi

    for s in "${disabled_services[@]}"; do
        systemctl stop "${s}"
        systemctl disable "${s}"
    done
    if on_edge "${1}"; then
        ETH0_USE_ROUTES=true
    else
        ETH0_USE_ROUTES=false
    fi
    sed "s/ETH0_USE_ROUTES/${ETH0_USE_ROUTES}/" \
        "/vagrant/netplan/${1}.yaml" | tee /etc/netplan/01-netcfg.yaml
    netplan apply
    systemctl restart lldpd
}

systemd_configuration() {
    systemctl disable systemd-resolved
    systemctl stop systemd-resolved
    rm -f /etc/resolv.conf
    nameservers=$(netplan ip leases eth0 | grep ^DNS= | sed 's/^DNS=//')
    for nameserver in ${nameservers}; do
        echo "nameserver ${nameserver}"
    done | tee /etc/resolv.conf
}

apt_configuration() {
    # ref: ansible/playbooks/roles/common/tasks/configure-bgp.yml
    if [ "$(lsb_release -sc)" == "bionic" ]; then
        cp "/vagrant/apt-preferences" /etc/apt/preferences.d/98-bird
    fi
}

package_installation() {
    dpkg --remove-architecture i386
    apt="sudo DEBIAN_FRONTEND=noninteractive \
        DEBIAN_PRIORITY=critical apt-get -y"
    ${apt} update
    ${apt} install lldpd bird2 iptables-persistent traceroute
}

opts=$(getopt E "$@")
# shellcheck disable=SC2086
set -- ${opts}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -E)
            on_edge_flag=1
            shift
            ;;
        *)
            shift
            break
            ;;
    esac
done

apt_configuration
package_installation
base_config "${1}"
switch_config "${1}"
systemd_configuration
exit 0
