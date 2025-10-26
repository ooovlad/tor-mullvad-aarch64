#!/usr/bin/env bash
set -e

if [ "$(id -u)" -ne 0 ]; then
  echo "Need to run with root privilege" >&2
  exit 1
fi

echo "Setting up build environment for Tor Browser and Mullvad Browser…"

# Set up environment variables
export HOME=${HOME:-/root}
export SHELL=/bin/bash
export DEBIAN_FRONTEND=noninteractive

# Update apt
if [ ! -f "/var/cache/apt/pkgcache.bin" ]; then
  echo "No previous update detected. Running apt update…"
  apt-get update -qq
elif [ $(($(date +%s) - $(stat -c %Y "/var/cache/apt/pkgcache.bin"))) -ge 3600 ]; then
  echo "Last apt update was 1 hour or more ago. Running apt update…"
  apt-get update -qq
else
  echo "Apt was updated less than 1 hour ago. Skipping apt update."
fi

# Install dependencies for Debian or Ubuntu described in readme: https://gitlab.torproject.org/tpo/applications/tor-browser-build/-/blob/main/README?ref_type=heads#:~:text=If%20you%20are%20running%20Debian%20or%20Ubuntu%2C%20you%20can%20install%20them%20with%3A
apt-get install -y -qq libdata-dump-perl libdata-uuid-perl libdatetime-perl \
  libdigest-sha-perl libfile-copy-recursive-perl \
  libfile-slurp-perl libio-all-perl libcapture-tiny-perl \
  libio-handle-util-perl libjson-perl \
  libparallel-forkmanager-perl libpath-tiny-perl \
  libsort-versions-perl libstring-shellquote-perl \
  libtemplate-perl libxml-libxml-perl libxml-writer-perl \
  libyaml-libyaml-perl git uidmap zstd jq 1> /dev/null

# Install dependencies that are not mentioned in readme but required, otherwise build fails
apt-get install -y -qq xz-utils unzip 1> /dev/null

# This one is from readme
sysctl -w kernel.unprivileged_userns_clone=1

# Install preferences for build-tor-mullvad.sh script
command -v tree &>/dev/null || apt-get install -y -qq tree 1> /dev/null

echo "Environment setup complete!"
echo "Perl version: $(perl -v | grep -ioE "v[.,0-9]+")" || echo "Perl version unknown"
echo "Python version: $(python3 --version)" || echo "Python version unknown"
echo "Available cores: $(nproc)" || true
echo "Available RAM: $(free -h | grep '^Mem:' | awk '{print $2}')" || true
echo "Available disk space: $(df -h / | awk 'NR==2 {print $4}')" || true
