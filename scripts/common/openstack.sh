# shellcheck shell=bash
# depends on: base.sh for: info, success, warn, die, apt_update, apt_install

install_openstack() {
  info 'Installing OpenStack client…'
  apt_update
  apt_install python3 virtualenv python3-pip jq

  virtualenv venv-openstack 1> /dev/null
  source venv-openstack/bin/activate
  pip3 install -qq python-openstackclient
  success 'OpenStack client (CLI) installed.'
  openstack --version
  OPENSTACK_VENV_PATH="$(pwd)/venv-openstack"
}

open_openstack() {
  if [ -z "$OPENSTACK_VENV_PATH" ]; then
    die 'OPENSTACK_VENV_PATH is not set. Cannot open OpenStack client. Try calling install_openstack function first.'
  fi
  source "$OPENSTACK_VENV_PATH/bin/activate"
}

ensure_network() {
  local name="$1"
  if openstack network show -f value -c id "$name" &>/dev/null; then
    info -n "Network exists: "
    success "$name"
  else
    info -n "Creating network $name… "
    openstack network create -f value -c name "$name" >/dev/null
    success "done"
  fi
}

ensure_subnet() {
  local name="$1" cidr="$2" net_name="$3"
  if openstack subnet show -f value -c id "$name" &>/dev/null; then
    info -n "Subnet exists: "
    success "$name"
  else
    info -n "Creating subnet $name ($cidr)… "
    openstack subnet create -f value -c name --subnet-range "$cidr" --network "$net_name" "$name" >/dev/null
    success "done"
  fi
}

ensure_external_network() {
  local provided_name="$1"
  local chosen=""
  if [ -n "$provided_name" ]; then
    local id
    if id="$(openstack network show -f value -c id "$provided_name" 2>/dev/null)"; then
      chosen="$id"
    else
      die "External network '$provided_name' not found"
    fi
  else
    # auto-select if exactly one external network
    local list
    list="$(openstack network list --external -f value -c id)" || die 'Unable to list external networks'
    local count
    count="$(echo "$list" | grep -c '.*' || true)"
    if [ "$count" = "1" ]; then
      chosen="$list"
    else
      die "Multiple or zero external networks found. Set OPENSTACK_EXT_NET explicitly."
    fi
  fi
  echo "$chosen"
}

ensure_router() {
  local router_name="$1" ext_net_id="$2" subnet_name="$3"
  local created=0
  if openstack router show -f value -c id "$router_name" &>/dev/null; then
    info -n "Router exists: "
    success "$router_name"
  else
    info -n "Creating router $router_name… "
    openstack router create -f value -c name "$router_name" >/dev/null
    success "done"
    created=1
  fi

  # Ensure subnet interface attached
  local subnet_id
  subnet_id="$(openstack subnet show -f value -c id "$subnet_name")" || die "Subnet $subnet_name not found"
  local if_present
  if_present="$(openstack router show -f json "$router_name" | jq -r --arg sid "$subnet_id" '.interfaces_info // [] | map(.subnet_id) | index($sid) | if .==null then "no" else "yes" end')"
  if [ "$if_present" != "yes" ]; then
    info -n "Attaching subnet $subnet_name to router $router_name… "
    openstack router add subnet "$router_name" "$subnet_name" >/dev/null
    success "done"
  fi

  # Ensure external gateway set
  local gw_ok
  gw_ok="$(openstack router show -f json "$router_name" | jq -r '.external_gateway_info.network_id // "" | if .=="" then "no" else "yes" end')"
  if [ "$gw_ok" != "yes" ] || [ "$created" = "1" ]; then
    info -n "Setting external gateway for router $router_name… "
    openstack router set --external-gateway "$ext_net_id" "$router_name" >/dev/null
    success "done"
  fi
}

ensure_keypair() {
  local key_name="$1" pubkey_path="$2"
  local out
  info -n "Creating keypair $key_name… "
  if ! out="$(openstack keypair create -f value -c name --public-key "$pubkey_path" "$key_name" 2>&1)"; then
    if [[ "$out" == *"already exists"* ]]; then
      openstack keypair delete "$key_name" >/dev/null
      openstack keypair create -f value -c name --public-key "$pubkey_path" "$key_name" >/dev/null || die "Unable to (re)create keypair $key_name"
      success "recreated"
      return 0
    else
      die "Uncaught exception while creating keypair: $out"
    fi
  fi
  success "done"
}

ensure_flavor() {
  local var="$1" prefix="$2" cpu="$3" ram_gib="$4" disk_gb="$5"
  local id="$prefix.$cpu.$ram_gib.$disk_gb"
  if openstack flavor show -f value -c name "$id" &>/dev/null; then
    eval "$var"="\"$id\""
    return 0
  fi
  info -n "Creating flavor… "
  if openstack flavor create -f value -c name --id "$id" --vcpus "$cpu" --ram "$((1024 * ram_gib))" --disk "$disk_gb" --private --project-domain "$OS_PROJECT_ID" --description "${cpu} vCPU, ${ram_gib}GiB RAM, ${disk_gb}GB local disk" -- "${cpu}cpu-${ram_gib}ram-${disk_gb}gb" >/dev/null; then
    success "done"
    eval "$var"="\"$id\""
    return 0
  fi
  warn "Unable to create new flavor. Selecting existing suitable flavor…"
  local found
  found="$(openstack flavor list --format json --noindent | jq -r --argjson cpu "$cpu" --argjson ram "$((1024 * ram_gib))" --argjson disk "$disk_gb" 'map(select(.VCPUs >= $cpu and .RAM >= $ram and .Disk >= $disk)) | sort_by(.VCPUs, .RAM, .Disk) | .[0].ID // empty')"
  if [ -z "$found" ]; then
    die "Unable to create/find flavor for this configuration: $cpu vCPU, $ram_gib GiB RAM, $disk_gb GB disk."
  fi
  info -n "Using existing flavor: "
  success "$found"
  eval "$var"="\"$found\""
}

create_server_wait() {
  local var="$1" name="$2" image="$3" network="$4" flavor="$5" key_name="$6" tags_str="$7"
  info -n "Creating server $name… "
  local -a tag_flags=()
  if [[ -n "$tags_str" ]]; then
    local t
    local -a _tags=()
    IFS=, read -r -a _tags <<< "$tags_str"
    for t in "${_tags[@]}"; do
      t="${t#"${t%%[![:space:]]*}"}"
      t="${t%"${t##*[![:space:]]}"}"
      [[ -n "$t" ]] && tag_flags+=( --tag "$t" )
    done
  fi
  local sid
  sid="$(openstack server create -f value -c id --image "$image" --network "$network" --flavor "$flavor" --key-name "$key_name" "${tag_flags[@]}" --wait -- "$name")" || die 'Unable to create server'
  eval "$var"="\"$sid\""
  success 'done'
}

ensure_server_status() {
  local name="$1"
  local status
  status="$(openstack server show -f value -c status "$name")"
  if [ "$status" != "ACTIVE" ]; then
    die "Server status is $status (expected ACTIVE). Server did not reach ACTIVE state."
  fi
  info "Server is ACTIVE"
}

allocate_or_reuse_fip() {
  local ext_net_id="$1"
  # Try reuse unassigned FIP from this external network
  local reused_id reused_ip
  reused_id="$(openstack floating ip list -f json --noindent | jq -r --arg n "$ext_net_id" '
    map(select((.Status=="DOWN" or ."Fixed IP Address"==null or ."Fixed IP Address"=="" or ."Fixed IP Address"=="None") and ."Floating Network"==$n))
    | .[0].ID // empty')"
  if [ -n "$reused_id" ]; then
    reused_ip="$(openstack floating ip show -f value -c floating_ip_address "$reused_id")"
    echo "$reused_id $reused_ip"
    return 0
  fi
  # Allocate new
  local out
  out="$(openstack floating ip create --format json --noindent "$ext_net_id" | jq -r '.id, .floating_ip_address' | xargs)" || die 'Unable to create floating IP'
  echo "$out"
}

associate_fip() {
  local server_name="$1" fip="$2"
  info -n "Associating floating IP with server $server_name… "
  openstack server add floating ip "$server_name" "$fip" >/dev/null
  success "done"
}

verify_fip_association() {
  local server_name="$1" fip="$2"
  local addresses
  addresses="$(openstack server show -f value -c addresses "$server_name" || true)"
  if [[ "$addresses" != *"$fip"* ]]; then
    die "Floating IP does not appear in server addresses for $server_name"
  fi
}

wait_ssh_ready() {
  local ip="$1" timeout_s="${2:-180}"
  info -n "Waiting for server SSH (timeout ${timeout_s}s)… "
  local start now
  start=$(date +%s)
  while true; do
    if ssh-keyscan -T 5 "$ip" &>/dev/null; then
      success 'ok'
      return 0
    fi
    now=$(date +%s)
    if [ $((now-start)) -ge "$timeout_s" ]; then
      die "SSH did not become ready within ${timeout_s}s"
    fi
    sleep 2
  done
}

extract_host_keys_from_console() {
  local server_name="$1" ip="$2" out_path="$3" timeout_s="${4:-300}"
  info -n "Waiting for SSH host keys in console log… "
  local start
  start=$(date +%s)
  local console
  while true; do
    console="$(openstack console log show "$server_name" || true)"
    if echo "$console" | grep -q -- "-----END SSH HOST KEY KEYS-----"; then
      break
    fi
    if [ $(( $(date +%s) - start )) -ge "$timeout_s" ]; then
      return 1
    fi
    sleep 10
  done
  success "ok"
  # Extract host keys (assuming format: algo base64 [comment])
  info -n "Extracting host keys… "
  rm -f "$out_path"
  echo "$console" | sed -n '/-----BEGIN SSH HOST KEY KEYS-----/,/-----END SSH HOST KEY KEYS-----/p' |
    grep -v 'BEGIN\|END' |
    while read -r line; do
      local ALGO BASE64
      ALGO=$(echo "$line" | awk '{print $1}')
      BASE64=$(echo "$line" | awk '{print $2}')
      if [ -n "$ALGO" ] && [ -n "$BASE64" ]; then
        echo "$ip $ALGO $BASE64" >> "$out_path"
      fi
    done
  sort -u "$out_path" -o "$out_path"
  success "done"
  return 0
}
