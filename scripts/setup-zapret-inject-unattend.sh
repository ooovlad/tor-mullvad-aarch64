#!/usr/bin/env bash
set -eo pipefail

# Inserts the embedded code (heredoc below) into the given input file
# right after the last function and before the rest of the code.

usage() {
  echo "Usage: $0 [-x|--execute] <input-file> [<output-file>]"
  echo "  -x, --execute   Execute the generated code immediately without writing an output file"
  echo "  -h, --help      Show this help message"
  echo
  echo "* Tip: Use with zapret configuration variables like IFACE_LAN=eth0, IFACE_WAN=wlan0."
  echo "       Copy and edit config file first because everything is disabled by default."
}

EXECUTE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -x|--execute)
      EXECUTE=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; break ;;
    -*)
      echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *)
      break ;;
  esac
done

if (( EXECUTE )); then
  if (( $# < 1 )); then
    echo -e "\e[38;5;160mError: missing <input-file>\e[0m" >&2; usage; exit 1
  fi
  in="$1"; shift
  if (( $# > 0 )); then
    echo -e "\e[38;5;160mError: too many arguments for execute mode\e[0m" >&2; usage; exit 1
  fi
else
  if (( $# != 2 )); then
    usage; exit 1
  fi
  in="$1"; out="$2"; shift 2
fi

if [[ ! -f "$in" ]]; then
  echo -e "\e[38;5;160mError: input file not found: $in\e[0m" >&2
  exit 1
fi

# Resolve input file to absolute path (without relying on readlink -f)
abs_in="$in"
case "$in" in
  /*) : ;; # already absolute
  *) abs_in="$(cd "$(dirname -- "$in")" && pwd -P)/$(basename -- "$in")" ;;
esac

# Embedded code to inject: edit the heredoc below
INJECT_CODE="$(cat <<'__INJECT_CODE__'
# Overwrite some functions for unattended installation
exitp() {
  exit $1
}
ask_yes_no()
{
	local DEFAULT=$1
	[ "$1" = "1" ] && DEFAULT=Y
	[ "$1" = "0" ] && DEFAULT=N
	[ -z "$DEFAULT" ] && DEFAULT=N
	printf "$2 (default : $DEFAULT) (Y/N) ? $DEFAULT <- unattended\n"
    [ "$DEFAULT" = "Y" ] || [ "$DEFAULT" = "1" ]
}
ask_list()
{
	# $1 - mode var
	# $2 - space separated value list
	# $3 - (optional) default value
	local M_DEFAULT
	eval M_DEFAULT="\$$1"
	local M_ALL=$M_DEFAULT
	local M=""
	local m
	
	[ -n "$3" ] && { find_str_in_list "$M_DEFAULT" "$2" || M_DEFAULT="$3" ;}
	
	n=1
	for m in $2; do
		echo $n : $m
		n=$(($n+1))
	done
	printf "your choice (default : $M_DEFAULT) : $M_DEFAULT <- unattended\n"
	M="$M_DEFAULT"
	echo selected : $M
	eval $1="\"$M\""
	
	[ "$M" != "$M_OLD" ]
}
__INJECT_CODE__
)"

if [[ -z "$INJECT_CODE" ]]; then
  echo -e "\e[38;5;160mError: embedded inject code is empty. Fill the heredoc assigned to INJECT_CODE.\e[0m" >&2
  exit 1
fi

# Check shebang in the first line of the input file
shebang=0
if IFS= read -r firstline < "$abs_in"; then
  if [[ "$firstline" =~ ^#! ]]; then
    shebang=1
  fi
fi

# Find the line number where the last function ends.
# Supported forms:
#   name() { ... }
#   function name() { ... }
#   function name { ... }
# Also supports placing "{" on the next line.
# Performs basic ignoring of quoted strings and # comments.
last_end="$(awk -f <(cat <<'AWK'
BEGIN {
  last_end = 0
  in_decl = 0
  awaiting_brace = 0
  in_func = 0
  depth = 0
}
# Process line: strip quoted content and comments, track {} balance.
function process_line(s,   i,c,q,net,clean) {
  net = 0; q = 0; clean = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s,i,1)
    if (q == 0) {
      if (c == "#") break
      if (c == "\"") { q = 2; clean = clean " "; continue }
      if (c == "'") { q = 1; clean = clean " "; continue }
      if (c == "{") { net++; clean = clean "{"; continue }
      if (c == "}") { net--; clean = clean "}"; continue }
      clean = clean c
    } else if (q == 2) {              # inside double quotes
      if (c == "\\") { i++; clean = clean " "; continue }
      if (c == "\"") { q = 0; clean = clean " "; continue }
      clean = clean " "
    } else if (q == 1) {              # inside single quotes
      if (c == "'") { q = 0; clean = clean " "; continue }
      clean = clean " "
    }
  }
  line_clean = clean
  return net
}
{
  net = process_line($0)

  if (in_func == 0) {
    if (in_decl == 0) {
      # Function declaration matches
      if (line_clean ~ /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)[[:space:]]*[{]?/ \
       || line_clean ~ /^[[:space:]]*function[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*([[:space:]]*\(\))?[[:space:]]*[{]?/) {
        in_decl = 1
        if (index(line_clean, "{") > 0) {
          in_decl = 0
          in_func = 1
          depth = 0
          depth += net
          if (depth < 1) depth = 1
        } else {
          awaiting_brace = 1
        }
      }
    } else {
      # After declaration, wait for opening {
      if (awaiting_brace) {
        if (index(line_clean, "{") > 0) {
          awaiting_brace = 0
          in_decl = 0
          in_func = 1
          depth = 0
          depth += net
          if (depth < 1) depth = 1
        }
      }
    }
  } else {
    # Inside function, track {} balance
    depth += net
    if (depth <= 0) {
      last_end = FNR
      in_func = 0
    }
  }
}
END {
  print last_end + 0
}
AWK
) "$abs_in")"

# Determine insertion line
insert_line=0
if [[ "$last_end" =~ ^[0-9]+$ ]] && (( last_end > 0 )); then
  insert_line=$last_end
else
  # No functions — insert after shebang (if present), otherwise at file start
  if (( shebang == 1 )); then
    insert_line=1
  else
    insert_line=0
  fi
fi

if (( EXECUTE )); then
  # Immediate execution in the input file's directory using the interpreter from shebang (if present)
  in_dir=$(dirname -- "$abs_in")
  interpreter_line=""
  if (( shebang == 1 )); then
    interpreter_line=${firstline#\#!}
  else
    interpreter_line="bash"
  fi
  # Parse interpreter and its arguments into an array
  # shellcheck disable=SC2206
  INTERP_ARR=( $interpreter_line )
  if (( ${#INTERP_ARR[@]} == 0 )); then
    INTERP_ARR=( bash )
  fi

  (
    cd "$in_dir" || exit 1
    fifo=$(mktemp -u ".inject.$$.XXXXXX.fifo")
    mkfifo "$fifo"
    # Remove FIFO on subprocess exit
    trap 'rm -f -- "$fifo"' EXIT INT TERM
    # Writer: build combined script stream into FIFO
    (
      if (( insert_line > 0 )); then head -n "$insert_line" "$abs_in"; fi
      printf '%s\n' "$INJECT_CODE"
      tail -n +"$((insert_line+1))" "$abs_in"
    ) >"$fifo" &
    writer_pid=$!
    # Launch interpreter, passing FIFO path as $0 (in the source directory)
    "${INTERP_ARR[@]}" "$fifo"
    status=$?
    # Wait for writer and exit with the same status
    wait "$writer_pid" 2>/dev/null || true
    exit "$status"
  )
else
  # Write to file
  # If input and output are the same — use a temporary file
  tmp=""
  if [[ "$in" == "$out" ]]; then
    tmp="$(mktemp)"
    out="$tmp"
  fi

  # Assemble result: head (up to insert_line) + INJECT_CODE + tail (after insert_line)
  : > "$out"
  if (( insert_line > 0 )); then
    head -n "$insert_line" "$abs_in" >> "$out"
  fi
  # Insert the code
  printf '%s\n' "$INJECT_CODE" >> "$out"
  # Rest of the source
  tail -n +"$((insert_line+1))" "$abs_in" >> "$out"

  # If it was in-place — overwrite the input file
  if [[ -n "${tmp:-}" ]]; then
    mv "$tmp" "$in"
  fi
fi

exit 0