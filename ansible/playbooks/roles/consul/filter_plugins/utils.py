"""
Copyright 2020, Bloomberg Finance L.P.
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
"""


class FilterModule(object):

    def filters(self):
        return {
            'groups_ips': self.get_groups_hosts_ips
        }

    def get_groups_hosts_ips(self, host_variables, selected_groups, groups, hostname):
        """Get hosts of the specified groups.

        Parameters:
        host_variables (dict): dict of hostvars
        selected_groups (list): list of groups to get their hosts
        groups (dict): list of groups
        hostname (string): current hostname

        Returns:
        hosts (set): list of hosts of the specified groups
        """
        hosts = set()
        for group in selected_groups:
            for host in groups[group]:
                if host != hostname:
                    hosts.add(host_variables[host]['interfaces']['service']['ip'])
        return list(hosts)
