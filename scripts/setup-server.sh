#!/usr/bin/env bash
set -eo pipefail

# Input variables (required):
# (These are set by collaborators under Settings -> Secrets and variables -> Actions, initialised in env section of a job/step)
#   OPENSTACK_RC_SECRETS=<openstack rc.sh file’s contents, including password, stored in this variable>;
#   OPENSTACK_FLAVOR_CPU=<amount of vCPU for build runner machine, e.g. "8">;
#   OPENSTACK_FLAVOR_RAM=<amount of RAM in GiB. e.g. "16">;
#   OPENSTACK_FLAVOR_DISK=<amount of local disk space in GB, e.g. "100">;
#   OPENSTACK_SERVER_IMAGE=<name or id of image for build runner machine, must be Debian/Ubuntu, to see what’s available run `openstack image list`>.

# Output:
#   Unencrypted: OPENSTACK_SERVER_ID OPENSTACK_SERVER_IP_ID >> GITHUB_OUTPUT
#   Encrypted: OPENSTACK_SERVER_SSHKEY OPENSTACK_SERVER_IP OPENSTACK_SERVER_SSHHOSTS >> GITHUB_OUTPUT
#   Files: id_ssh, id_ssh.pub, known_hosts, ip_ssh.txt

# Source common functions
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "$SCRIPT_DIR/common/base.sh"
source "$SCRIPT_DIR/common/openstack.sh"

# Parameters and defaults
: "${OPENSTACK_RC_SECRETS:=}"
: "${OPENSTACK_FLAVOR_CPU:?'OPENSTACK_FLAVOR_CPU variable is not set, cannot continue.'}"
: "${OPENSTACK_FLAVOR_RAM:?'OPENSTACK_FLAVOR_RAM variable is not set, cannot continue.'}"
: "${OPENSTACK_FLAVOR_DISK:?'OPENSTACK_FLAVOR_DISK variable is not set, cannot continue.'}"
: "${OPENSTACK_SERVER_IMAGE:?'OPENSTACK_SERVER_IMAGE variable is not set, cannot continue.'}"
# Resources names/configs
: "${OPENSTACK_NETWORK:=network_ci}"
: "${OPENSTACK_SUBNET:=subnet_ci}"
: "${OPENSTACK_SUBNET_CIDR:=192.168.0.0/24}"
: "${OPENSTACK_ROUTER:=router_ci}"
: "${OPENSTACK_KEYPAIR:=keypair_autorunner_${OPENSTACK_SUFFIX:=$(mktemp -u XXXXXXXX)}}"
: "${OPENSTACK_SERVER_NAME:=autorunner_${OPENSTACK_SUFFIX:=$(mktemp -u XXXXXXXX)}}"
# Tags, comma-separated
: "${OPENSTACK_SERVER_TAGS:=preemptible,autorunner}"
# External network: if empty — will be selected automatically, if only one
: "${OPENSTACK_EXT_NET:=}"
# Prefix for custom flavor
: "${OPENSTACK_FLAVOR_PREFIX:=custom}"
: "${ROTATION_PASSPHRASE:?'ROTATION_PASSPHRASE variable is not set, cannot continue.'}"

# Predictable local files (used by other scripts)
PRIVKEY_PATH="id_ssh"
PUBKEY_PATH="$PRIVKEY_PATH.pub"
KNOWN_HOSTS_PATH="known_hosts"

install_openstack
command -v openssl &>/dev/null || {
  info 'Installing openssl… '
  apt_install openssl
  success 'done'
}

# Load auth info
info -n 'Loading credentials for OpenStack… '
if [ -z "$OPENSTACK_RC_SECRETS" ]; then
  if [ -f rc.sh ]; then
    info -n 'Using rc.sh from current directory… '
    source rc.sh
  elif [ -f "$SCRIPT_DIR/rc.sh" ]; then
    info -n "Using rc.sh from $SCRIPT_DIR… "
    source "$SCRIPT_DIR/rc.sh"
  else
    die 'OPENSTACK_RC_SECRETS is empty, rc.sh not found, cannot continue.'
  fi
else
  source /dev/stdin <<<"$OPENSTACK_RC_SECRETS"
fi
if [ -z "${OS_PASSWORD:-}" ]; then
  die 'OS_PASSWORD is empty, check OPENSTACK_RC_SECRETS variable or rc.sh file.'
fi
success 'done'

# Output filters
exec 2> >(sed -E 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/***/g; s@https?://[^\ ]+@***@g' >&2)

# Create network and subnet
ensure_network "$OPENSTACK_NETWORK"
ensure_subnet "$OPENSTACK_SUBNET" "$OPENSTACK_SUBNET_CIDR" "$OPENSTACK_NETWORK"

# Create SSH keypair
ssh-keygen -t ed25519 -f "$PRIVKEY_PATH" -C 'openstack' -N '' -q
ensure_keypair "$OPENSTACK_KEYPAIR" "$PUBKEY_PATH"
# Mask private key in GitHub logs
if [ -s "$PRIVKEY_PATH" ]; then
  while IFS= read -r line; do echo "::add-mask::$line" >&2; done < "$PRIVKEY_PATH"
fi
output OPENSTACK_SERVER_SSHKEY "$(openssl enc -aes-256-cbc -pbkdf2 -salt -in "$PRIVKEY_PATH" -k "$ROTATION_PASSPHRASE" -a -A)" || true

# Create flavor
OPENSTACK_FLAVOR_ID=""
ensure_flavor OPENSTACK_FLAVOR_ID "$OPENSTACK_FLAVOR_PREFIX" "$OPENSTACK_FLAVOR_CPU" "$OPENSTACK_FLAVOR_RAM" "$OPENSTACK_FLAVOR_DISK"

# Create server
OPENSTACK_SERVER_ID=""
create_server_wait OPENSTACK_SERVER_ID "$OPENSTACK_SERVER_NAME" "$OPENSTACK_SERVER_IMAGE" "$OPENSTACK_NETWORK" "$OPENSTACK_FLAVOR_ID" "$OPENSTACK_KEYPAIR" "$OPENSTACK_SERVER_TAGS"
output OPENSTACK_SERVER_ID "$OPENSTACK_SERVER_ID" || true
openstack keypair delete "$OPENSTACK_KEYPAIR" >/dev/null 2>&1 || true
ensure_server_status "$OPENSTACK_SERVER_ID"

# Create router
OPENSTACK_EXT_NET_ID="$(ensure_external_network "$OPENSTACK_EXT_NET")" || die 'Unable to get external network id'
ensure_router "$OPENSTACK_ROUTER" "$OPENSTACK_EXT_NET_ID" "$OPENSTACK_SUBNET"

# Create or reuse floating IP and associate it with server
read -r OPENSTACK_SERVER_IP_ID OPENSTACK_SERVER_IP <<< "$(allocate_or_reuse_fip "$OPENSTACK_EXT_NET_ID")"
output OPENSTACK_SERVER_IP_ID "$OPENSTACK_SERVER_IP_ID" || true
if [ -z "$OPENSTACK_SERVER_IP_ID" ]; then
  die 'Unable to get ID of floating IP'
elif [ -z "$OPENSTACK_SERVER_IP" ]; then
  openstack floating ip delete "$OPENSTACK_SERVER_IP_ID" || true
  die 'Unable to get IP address of floating IP. Deleted.'
fi
associate_fip "$OPENSTACK_SERVER_NAME" "$OPENSTACK_SERVER_IP_ID"
verify_fip_association "$OPENSTACK_SERVER_NAME" "$OPENSTACK_SERVER_IP"
echo "$OPENSTACK_SERVER_IP" > ip_ssh.txt
echo "::add-mask::$OPENSTACK_SERVER_IP" >&2
output OPENSTACK_SERVER_IP "$(echo "$OPENSTACK_SERVER_IP" | openssl enc -aes-256-cbc -pbkdf2 -salt -k "$ROTATION_PASSPHRASE" -a -A)" || true

# Wait for server to be SSH-ready
wait_ssh_ready "$OPENSTACK_SERVER_IP" 180

# Extract host keys from console log or ssh-keyscan
if ! extract_host_keys_from_console "$OPENSTACK_SERVER_NAME" "$OPENSTACK_SERVER_IP" "$KNOWN_HOSTS_PATH" 300; then
  warn "Host keys not found in console log after timeout; will fallback to ssh-keyscan"
  ssh-keyscan -T 5 "$OPENSTACK_SERVER_IP" > "$KNOWN_HOSTS_PATH" 2>/dev/null || true
  sort -u "$KNOWN_HOSTS_PATH" -o "$KNOWN_HOSTS_PATH" || true
fi
output OPENSTACK_SERVER_SSHHOSTS "$(openssl enc -aes-256-cbc -pbkdf2 -salt -in "$KNOWN_HOSTS_PATH" -k "$ROTATION_PASSPHRASE" -a -A)" || true
success "Server setup completed successfully."
