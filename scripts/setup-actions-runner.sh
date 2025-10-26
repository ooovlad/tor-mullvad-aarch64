#!/usr/bin/env bash
set -eo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo 'Need to run with sudo privilege' >&2
  exit 1
fi

if [ -z "$REPO" ] || [ -z "$TOKEN" ]; then
  echo 'Error: You must provide repository URL as REPO variable and runner registration token as TOKEN variable.' >&2
  exit 1
elif [ -z "$NAME" ]; then
  NAME="$(mktemp 'autorunner-XXXX')"
fi

echo 'Updating apt repositories, upgrading packages…'
apt-get update -qq && apt-get full-upgrade -y -qq
echo 'Installing required apt packages…'
apt-get install -y -qq git wget curl tar jq ca-certificates 1> /dev/null

echo 'Creating user actions…'
adduser --disabled-password --gecos "" actions
printf '%s ALL=(ALL) NOPASSWD:ALL\n' actions | tee /etc/sudoers.d/actions-nopassword > /dev/null
chown root:root /etc/sudoers.d/actions-nopassword
chmod 440 /etc/sudoers.d/actions-nopassword

echo 'Creating installation directory…'
mkdir -p /opt/actions-runner && chown actions:actions /opt/actions-runner
cd /opt/actions-runner

echo 'Downloading latest GitHub Actions Runner release…'
sudo -u actions -- bash << 'EOSUDO'
  set -euo pipefail
  VER=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -er .tag_name | tr -d v)
  curl -fsSLo /tmp/actions-runner-linux-x64.tar.gz "https://github.com/actions/runner/releases/download/v${VER}/actions-runner-linux-x64-${VER}.tar.gz"
  unset VER
  tar xzf /tmp/actions-runner-linux-x64.tar.gz
  rm /tmp/actions-runner-linux-x64.tar.gz
EOSUDO

echo 'Installing dependencies…'
./bin/installdependencies.sh

echo 'Configuring/registering actions runner…'
sudo -u actions ./config.sh --url "https://github.com/$REPO" --token "$TOKEN" --name "$NAME" --work _ci_work --labels "${LABELS:-ci}" --unattended

echo 'Installing and starting service…'
./svc.sh install actions
./svc.sh start

unset REPO
unset TOKEN
unset RUNNER
unset LABELS
