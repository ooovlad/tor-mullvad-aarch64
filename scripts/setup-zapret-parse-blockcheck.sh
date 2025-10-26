#!/usr/bin/env bash

# Blockcheck summary parser for zapret. Tested on v72.2 (Oct 19, 2025). Author: GitHub Coding Agent.
# Parse blockcheck.sh output and apply working strategy to config
# - Reads the SUMMARY section of blockcheck output
# - Copies config.default to config if config doesn't exist
# - Enables either NFQWS or TPWS (preferring NFQWS by default if both present)
# - Writes corresponding *_OPT multi-line value with proper --filter-... lines
#
# Usage:
#   ./parse_blockcheck_summary.sh [-i blockcheck.log] [-c config] [-d config.default] [--prefer tpws|nfqws]
#   cat blockcheck.log | ./parse_blockcheck_summary.sh

set -eo pipefail

PREFER_TOOL="nfqws"
CONFIG_FILE="config"
CONFIG_DEFAULT="config.default"
INPUT_FILE=""

print_usage() {
  echo "Usage: $0 [-i blockcheck.log] [-c config] [-d config.default] [--prefer tpws|nfqws]" >&2
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)
      INPUT_FILE="$2"; shift 2;;
    -c|--config)
      CONFIG_FILE="$2"; shift 2;;
    -d|--default)
      CONFIG_DEFAULT="$2"; shift 2;;
    --prefer)
      case "${2:-}" in
        tpws|nfqws) PREFER_TOOL="$2";;
        *) echo "--prefer must be 'tpws' or 'nfqws'" >&2; exit 2;;
      esac
      shift 2;;
    -h|--help)
      print_usage; exit 0;;
    *)
      echo "Unknown argument: $1" >&2
      print_usage; exit 2;;
  esac
done

if [[ -n "$INPUT_FILE" && ! -f "$INPUT_FILE" ]]; then
  echo "Input file not found: $INPUT_FILE" >&2
  exit 2
fi

# Read SUMMARY lines from either file or stdin
read_summary_lines() {
  if [[ -n "$INPUT_FILE" ]]; then
    awk 'found && /^curl_test_/ {print} /^\* SUMMARY/ {found=1}' "$INPUT_FILE"
  else
    awk 'found && /^curl_test_/ {print} /^\* SUMMARY/ {found=1}'
  fi
}

# Collect params per tool and test type
declare -A tpws_params
declare -A nfqws_params

summ_lines=$(read_summary_lines)

if [[ -z "$summ_lines" ]]; then
  echo "No SUMMARY lines found in input. Ensure you pass the full blockcheck output or a file containing it." >&2
  exit 1
fi

while IFS= read -r line; do
  # Example line:
  # curl_test_http ipv4 mullvad.net : nfqws --methodeol
  # curl_test_https_tls12 ipv4 mullvad.net : nfqws --dpi-desync=multidisorder --dpi-desync-split-pos=1
  test_name=$(awk '{print $1}' <<<"$line")
  tool=$(sed -n 's/.*: \(tpws\|nfqws\) .*/\1/p' <<<"$line")
  params=$(sed -n 's/.*: \(tpws\|nfqws\) \(.*\)$/\2/p' <<<"$line")

  [[ -z "$tool" || -z "$params" ]] && continue

  case "$test_name" in
    curl_test_http)
      key=http;;
    curl_test_https_tls12)
      key=tls12;;
    curl_test_https_tls13)
      key=tls13;;
    curl_test_quic_http3|curl_test_http3|curl_test_quic)
      key=http3;;
    *)
      # Unknown test type; skip
      continue;;
  esac

  if [[ "$tool" == "tpws" ]]; then
    tpws_params["$key"]="$params"
  else
    nfqws_params["$key"]="$params"
  fi
done <<<"$summ_lines"

# Decide which tool to enable
tool_choice=""
if (( ${#nfqws_params[@]} > 0 )) && (( ${#tpws_params[@]} > 0 )); then
  tool_choice="$PREFER_TOOL"
elif (( ${#nfqws_params[@]} > 0 )); then
  tool_choice="nfqws"
elif (( ${#tpws_params[@]} > 0 )); then
  tool_choice="tpws"
else
  echo "No recognized strategies found in SUMMARY." >&2
  exit 1
fi

echo "Detected strategies: tpws=${#tpws_params[@]}, nfqws=${#nfqws_params[@]}. Choosing: $tool_choice" >&2

# Ensure config exists
if [[ ! -f "$CONFIG_FILE" ]]; then
  if [[ ! -f "$CONFIG_DEFAULT" ]]; then
    echo "Default config not found: $CONFIG_DEFAULT" >&2
    exit 2
  fi
  cp -a "$CONFIG_DEFAULT" "$CONFIG_FILE"
  echo "Created $CONFIG_FILE from $CONFIG_DEFAULT" >&2
fi

# Helper: set simple VAR=value (enable/disable flags)
set_flag() {
  local var="$1"; local val="$2"; local file="$3"
  if grep -qE "^${var}=" "$file"; then
    sed -i -E "s|^(${var}=).*|\\1${val}|" "$file"
  else
    printf '\n%s=%s\n' "$var" "$val" >> "$file"
  fi
}

# Helper: replace a multi-line VAR="..." block with provided content lines
replace_multiline_var() {
  local var="$1"; shift
  local file="$1"; shift
  local content="$*"

  # Build safe temp file
  local tmp
  tmp=$(mktemp)

  if grep -qE "^${var}=\"" "$file"; then
    awk -v VAR="$var" -v CONTENT="$content" '
      BEGIN {inblk=0}
      $0 ~ ("^" VAR "=\"") {
        print VAR "=\"";
        # Split CONTENT by \n and print as-is
        n=split(CONTENT, a, /\n/);
        for (i=1;i<=n;i++) print a[i];
        print "\"";
        inblk=1; next
      }
      inblk {
        if ($0 ~ /^"$/) { inblk=0; next } else { next }
      }
      { print }
    ' "$file" >"$tmp"
  else
    # Append new var at end
    cat "$file" >"$tmp"
    {
      echo ""
      echo "$var=\""
      printf "%s\n" "$content"
      echo '"'
    } >>"$tmp"
  fi

  mv "$tmp" "$file"
}

build_tpws_content() {
  local lines=()
  if [[ -n "${tpws_params[http]:-}" ]]; then
    lines+=("--filter-tcp=80 ${tpws_params[http]} <HOSTLIST> --new")
  fi
  local p443="${tpws_params[tls13]:-${tpws_params[tls12]:-}}"
  if [[ -n "$p443" ]]; then
    lines+=("--filter-tcp=443 $p443 <HOSTLIST> --new")
  fi
  if [[ -n "${tpws_params[http3]:-}" ]]; then
    lines+=("--filter-udp=443 ${tpws_params[http3]} <HOSTLIST_NOAUTO>")
  fi
  local IFS=$'\n'
  echo "${lines[*]}"
}

build_nfqws_content() {
  local lines=()
  if [[ -n "${nfqws_params[http]:-}" ]]; then
    lines+=("--filter-tcp=80 ${nfqws_params[http]} <HOSTLIST> --new")
  fi
  local p443="${nfqws_params[tls13]:-${nfqws_params[tls12]:-}}"
  if [[ -n "$p443" ]]; then
    lines+=("--filter-tcp=443 $p443 <HOSTLIST> --new")
  fi
  if [[ -n "${nfqws_params[http3]:-}" ]]; then
    lines+=("--filter-udp=443 ${nfqws_params[http3]} <HOSTLIST_NOAUTO>")
  fi
  local IFS=$'\n'
  echo "${lines[*]}"
}

# Build NFQWS_OPT/TWPS_OPT and set flags
case "$tool_choice" in
  nfqws)
    nfqws_content=$(build_nfqws_content)
    replace_multiline_var "NFQWS_OPT" "$CONFIG_FILE" "$nfqws_content"
    set_flag "NFQWS_ENABLE" 1 "$CONFIG_FILE"
    set_flag "TPWS_ENABLE" 0 "$CONFIG_FILE"
    ;;
  tpws)
    tpws_content=$(build_tpws_content)
    replace_multiline_var "TPWS_OPT" "$CONFIG_FILE" "$tpws_content"
    set_flag "TPWS_ENABLE" 1 "$CONFIG_FILE"
    set_flag "NFQWS_ENABLE" 0 "$CONFIG_FILE"
    ;;
esac

echo "Updated $CONFIG_FILE for $tool_choice strategies." >&2