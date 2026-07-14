#!/usr/bin/env bash

load_config_file() {
  local file="$1" line key value line_number=0
  [[ -f "$file" ]] || { echo "ERROR: config file not found: $file" >&2; exit 2; }

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || {
      echo "ERROR: $file:$line_number must use key=value" >&2
      exit 2
    }
    key="${line%%=*}"
    value="${line#*=}"
    key="${key//[[:space:]]/}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    set_config_value "$key" "$value" "$file:$line_number"
  done < "$file"
}

find_config_argument() {
  local previous="" arg
  CONFIG_FILE=""
  for arg in "$@"; do
    if [[ "$previous" == "--config" ]]; then
      CONFIG_FILE="$arg"
      previous=""
      continue
    fi
    case "$arg" in
      --config) previous="--config" ;;
      --config=*) CONFIG_FILE="${arg#*=}" ;;
    esac
  done
  [[ "$previous" != "--config" ]] || { echo "ERROR: --config requires a value" >&2; exit 2; }
  : "$CONFIG_FILE"
}

require_boolean() {
  [[ "$2" == true || "$2" == false ]] || {
    echo "ERROR: $1 must be true or false, got '$2'" >&2
    exit 2
  }
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '%s' "$value"
}

write_attempt_log() {
  local file="$1" tool="$2" attempt="$3" zone="$4" machine_type="$5" result="$6"
  [[ -n "$file" ]] || return 0
  printf '{"timestamp":"%s","tool":"%s","attempt":%d,"zone":"%s","machine_type":"%s","result":"%s"}\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$(json_escape "$tool")" \
    "$attempt" \
    "$(json_escape "$zone")" \
    "$(json_escape "$machine_type")" \
    "$(json_escape "$result")" >> "$file"
}

backoff_delay() {
  local base="$1" maximum="$2" failures="$3" i jitter
  local delay="$base"
  if [[ $base -eq 0 ]]; then
    echo 0
    return
  fi
  for ((i = 1; i < failures && delay < maximum; i++)); do
    delay=$((delay * 2))
    [[ $delay -le $maximum ]] || delay=$maximum
  done
  jitter=$((RANDOM % (delay / 4 + 1)))
  delay=$((delay + jitter))
  [[ $delay -le $maximum ]] || delay=$maximum
  echo "$delay"
}

sleep_after_failure() {
  local base="$1" maximum="$2" failures="$3" delay
  delay="$(backoff_delay "$base" "$maximum" "$failures")"
  echo "  retrying in ${delay}s"
  sleep "$delay"
}
