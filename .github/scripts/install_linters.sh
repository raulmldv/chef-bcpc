#!/bin/bash -x

function main {
    install_linters_linux
}

function install_linters_linux {
    sudo apt-get install -y shellcheck
    sudo pip install bashate flake8 ansible-core==2.11.5 ansible-lint==5.2.0
    sudo gem install cookstyle
}

main
