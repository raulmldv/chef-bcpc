#!/bin/bash

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

set -xe


packer_dir=$(dirname "$(dirname "$0")")

# Check if an official base box is added to vagrant
config_variables="${packer_dir}/config/variables.json"
BASE_BOX=$(jq -r '.base_box' "$config_variables")
BASE_BOX_VERSION=$(jq -r '.base_box_version' "$config_variables")
BASE_BOX_PROVIDER=$(jq -r '.base_box_provider' "$config_variables")
OUTPUT_PACKER_BOX_NAME=$(jq -r '.output_packer_box_name' "$config_variables")
if [ "$BASE_BOX" == "null" ] \
   || [ "$BASE_BOX_VERSION" == "null" ] \
   || [ "$OUTPUT_PACKER_BOX_NAME" == "null" ]; then
    printf "One or more variables in %s are undefined.\n" "$config_variables"
    exit 1
fi
base_box_exists=$(
    vagrant box list --machine-readable |
    grep -i "${BASE_BOX}.*${BASE_BOX_PROVIDER}.*${BASE_BOX_VERSION}" \
    || true
)
if [ -z "$base_box_exists" ]; then
    vagrant box add \
        --force \
        --insecure "$BASE_BOX" \
        --box-version "$BASE_BOX_VERSION" \
        --provider virtualbox;
    if [ "$BASE_BOX_PROVIDER" == "libvirt" ]; then
        printf "Checking for vagrant mutate"
        mutate=$(vagrant plugin list | grep mutate)
        if [ -z "$mutate" ]; then
            printf "Vagrant mutate not found. "
            printf "Please install vagrant mutate to allow base conversion\n"
            exit 1
        else
            printf "Vagrant mutate found, mutating VirtualBox version...\n"
            vagrant mutate "${BASE_BOX}" --input-provider virtualbox libvirt
        fi
    fi
fi

# prevent vagrant-libvirt from failing if there's scrapnel lying around
if [ "$VAGRANT_DEFAULT_PROVIDER" == "libvirt" ]; then
    virsh destroy output-vagrant_source || true
    virsh undefine output-vagrant_source || true
    virsh vol-delete --pool default output-vagrant_source.img || true
fi

# create the packer box
# Use the script path to find the packer directory
cd "$packer_dir"
if ! command -v "packer" &> /dev/null; then
    printf "Command packer not found. Please check if it is installed.\n"
    exit 1
fi
if [ -d "output-vagrant" ]; then
    rm -drf output-vagrant
fi
current_packer_ver=$(packer --version)
required_packer_ver="1.4.0"
lower_packer_ver=$(printf '%s\n' "$required_packer_ver" "$current_packer_ver" \
                    | sort -V \
                    | head -n1)
if [ "$lower_packer_ver" = "$required_packer_ver" ]; then
    VAGRANT_VAGRANTFILE=Vagrantfile packer build \
                        --force \
                        --on-error=abort \
                        --var-file="config/variables.json" \
                        "config/config.json"
    cd "output-vagrant"
    VAGRANT_VAGRANTFILE=Vagrantfile vagrant box add \
                        --force \
                        --clean \
                        --name "$OUTPUT_PACKER_BOX_NAME" \
                        file://package.box
else
    printf "Packer version is too low. Please install at least %s\n." \
        "$required_packer_ver"
    exit 1
fi
