#!/bin/bash -x

# Copyright 2021, Bloomberg Finance L.P.
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

set -ev

function main {
    # shellcheck disable=SC1091
    source /tmp/linter_venv/bin/activate

    find . -name "*.sh" -exec shellcheck {} \;
    find . -name "*.sh" -exec bashate -e E006 {} \;
    find . -name "*.py" \
         ! -path "./chef/cookbooks/bcpc/files/default/*" \
         -exec flake8 {} \;
    ansible-lint -x var-naming \
                 -x meta-no-info \
                 -x meta-no-tags ansible/
    cookstyle --version && cookstyle .
}

main
