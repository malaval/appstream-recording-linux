#!/bin/bash -e

cd /tmp

echo "Installing the last version of AWS CLI"
mkdir awscliv2
cd awscliv2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install
cd ..
rm -rf awscliv2

echo "Installing the Session Manager plugin"
mkdir session-manager-plugin
cd session-manager-plugin
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm" -o "session-manager-plugin.rpm"
yum install -y session-manager-plugin.rpm
cd ..
rm -rf session-manager-plugin
