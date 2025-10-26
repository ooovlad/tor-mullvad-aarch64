# shellcheck shell=bash

die() {
  echo -e "\n\e[91mError: $1\e[0m" >&2
  exit 1
}

success() {
  echo -e "\e[92m$1\e[0m" >&2
}

warn() {
  echo -e "\e[93mWarning: $1\e[0m" >&2
}

info() {
  if [[ "$1" == '-'* ]] && [ -n "$2" ]; then
    echo -e "$1" "\e[38;5;26m$2\e[0m" >&2
  else
    echo -e "\e[38;5;26m$1\e[0m" >&2
  fi
}

apt_update() {
  if [ ! -f "/var/cache/apt/pkgcache.bin" ]; then
    echo "Running apt update…" >&2
    sudo apt-get update -qq
  elif [ $(($(date +%s) - $(stat -c %Y "/var/cache/apt/pkgcache.bin"))) -ge 3600 ]; then
    echo "Last apt update was 1 hour or more ago. Running apt update…" >&2
    sudo apt-get update -qq
  else
    echo "Apt was updated less than 1 hour ago. Skipping apt update." >&2
  fi
}

apt_install() {
  local packages=("$@")
  sudo apt-get install -y -qq "${packages[@]}" 1> /dev/null
}

output() {
  # $1 - variable name; $2 - variable value
  if [ -n "$GITHUB_OUTPUT" ]; then
    if [[ "$2" == *$'\n'* ]]; then
      local delimiter
      delimiter=$'\uE001'"__MULTILINE_CONTENT__"$'\uE001'
      {
        echo "$1<<$delimiter"
        echo "$2"
        echo "$delimiter"
      } >> "$GITHUB_OUTPUT"
    else
      echo "$1=$2" >> "$GITHUB_OUTPUT"
    fi
    return 0
  else
    warn "GITHUB_OUTPUT is not set; cannot write output variable $1"
    return 1
  fi
}