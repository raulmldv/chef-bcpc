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
            'hosts_chef_role': self.get_hosts_chef_role
        }

    def get_hosts_chef_role(self, hosts, host_variables, chef_role):
        """Get hosts with specified chef role.

        Parameters:
        hosts (list): list of hosts to check for roles
        host_variables (dict): dict of hostvars
        chef_role (str): role to filter the hosts with

        Returns:
        hosts_with_role (set): list of hosts with specified role
        """
        chef_role = "role[" + chef_role + "]"
        hosts_with_role = set()
        for host in hosts:
            for role in host_variables[host]['run_list']:
                if role == chef_role:
                    hosts_with_role.add(host)
        return list(hosts_with_role)
