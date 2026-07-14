#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cp "$ROOT/grab_capacity.sh" "$ROOT/grab_reservations.sh" \
  "$ROOT/release_capacity.sh" "$ROOT/release_reservations.sh" "$TMP/"
mkdir "$TMP/bin" "$TMP/lib"
cp "$ROOT/lib/common.sh" "$TMP/lib/"
export MOCK_CALLS="$TMP/calls"

cat > "$TMP/bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "terraform $*" >> "$MOCK_CALLS"
marker="${TF_DATA_DIR:-.terraform}/mock-state"
case "$1" in
  init) mkdir -p "${TF_DATA_DIR:-.terraform}" ;;
  validate) ;;
  console)
    read -r expression
    if [[ "$expression" == contains* ]]; then echo true; else echo '"test-project"'; fi
    ;;
  apply)
    case "${MOCK_TF_APPLY:-stockout}" in
      success) mkdir -p "$(dirname "$marker")"; touch "$marker" ;;
      state_error) mkdir -p "$(dirname "$marker")"; touch "$marker"; echo "apply failed" >&2; exit 1 ;;
      stockout) echo "ZONE_RESOURCE_POOL_EXHAUSTED" >&2; exit 1 ;;
      *) echo "configuration error" >&2; exit 1 ;;
    esac
    ;;
  state)
    case "$2" in
      list) [[ ! -f "$marker" ]] || echo "google_compute_instance.grab" ;;
      show) echo 'resource "google_compute_instance" "grab" {}' ;;
    esac
    ;;
  output) echo 'instance_name = "test-instance"' ;;
  destroy) rm -f "$marker" ;;
  *) echo "unexpected terraform arguments: $*" >&2; exit 1 ;;
esac
EOF

cat > "$TMP/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud $*" >> "$MOCK_CALLS"
case "$1 $2 $3" in
  "config get-value project") echo "test-project" ;;
  "projects describe test-project") echo "test-project" ;;
  "compute zones list") printf '%s\n' us-central1-a us-central1-b ;;
  "compute machine-types describe") echo "$4" ;;
  "compute reservations create")
    if [[ "${MOCK_GCLOUD_CREATE:-success}" == stockout ]]; then
      echo "ZONE_RESOURCE_POOL_EXHAUSTED" >&2
      exit 1
    fi
    printf '%s\n' "$4" > "$MOCK_NAME_FILE"
    ;;
  "compute reservations delete") ;;
  *) echo "unexpected gcloud arguments: $*" >&2; exit 1 ;;
esac
EOF

chmod +x "$TMP/bin/terraform" "$TMP/bin/gcloud"
export PATH="$TMP/bin:$PATH"

run() {
  if OUTPUT=$("$@" 2>&1); then STATUS=0; else STATUS=$?; fi
}

assert_status() {
  [[ $STATUS -eq $1 ]] || {
    echo "expected status $1, got $STATUS" >&2
    echo "$OUTPUT" >&2
    exit 1
  }
}

assert_output() {
  [[ "$OUTPUT" == *"$1"* ]] || {
    echo "expected output to contain: $1" >&2
    echo "$OUTPUT" >&2
    exit 1
  }
}

assert_file_contains() {
  grep -q -- "$2" "$1" || { echo "expected $1 to contain: $2" >&2; exit 1; }
}

cat > "$TMP/capacity.conf" <<'EOF'
machine_types=n2-highmem-64
zones=us-central1-a
delay=30
max_delay=60
max_attempts=1
run_id=config-run
EOF

run "$TMP/grab_capacity.sh" --config "$TMP/capacity.conf" --delay 0 --max-delay 0
assert_status 1
assert_output "run ID        : config-run"
assert_output "STOCKOUT"
assert_file_contains "$TMP/.runs/config-run/attempts.jsonl" '"result":"stockout"'

run env MOCK_TF_APPLY=state_error "$TMP/grab_capacity.sh" --machine-types n2-highmem-64 \
  --zones us-central1-a --delay 0 --max-delay 0 --run-id ambiguous-run
assert_status 1
assert_output "STATE PRESENT"
assert_output "to avoid replacing possible secured capacity"

run env MOCK_TF_APPLY=success "$TMP/grab_capacity.sh" --machine-types n2-highmem-64 \
  --zones us-central1-a --delay 0 --max-delay 0 --run-id successful-run
assert_status 0
assert_output "./release_capacity.sh --run-id successful-run"
[[ -f "$TMP/.runs/successful-run/winner.tfvars" ]] || { echo "winner vars not written" >&2; exit 1; }
assert_file_contains "$MOCK_CALLS" '.runs/successful-run/terraform.tfstate'

run "$TMP/grab_capacity.sh" --machine-types n2-highmem-64 --zones us-central1-a \
  --delay 0 --max-delay 0 --run-id successful-run
assert_status 1
assert_output "already manages a grabbed instance"

mkdir "$TMP/.runs/successful-run/.lock"
run "$TMP/release_capacity.sh" --run-id successful-run --yes
assert_status 1
assert_output "is active or has a stale lock"
rmdir "$TMP/.runs/successful-run/.lock"

run "$TMP/release_capacity.sh" --run-id successful-run --yes
assert_status 0
assert_output "Released run 'successful-run'"
[[ ! -d "$TMP/.runs/successful-run" ]] || { echo "run directory was not removed" >&2; exit 1; }

run "$TMP/grab_capacity.sh" --machine-types n2-highmem-64 --zones us-central1-a \
  --delay 0 --max-delay 0 --run-id preflight-run --check-only
assert_status 0
assert_output "OK n2-highmem-64 in us-central1-a"
assert_output "require environment-specific verification"

run "$TMP/grab_reservations.sh" --machine-type n2-highmem-64 --region us-central1 \
  --zones us-east1-b --delay 0 --max-delay 0 --count 1
assert_status 2
assert_output "is not in region 'us-central1'"

export MOCK_NAME_FILE="$TMP/reservation-name"
run "$TMP/grab_reservations.sh" --machine-type n2-highmem-128 --region northamerica-northeast2 \
  --zones northamerica-northeast2-a --delay 0 --max-delay 0 --count 1 --specific
assert_status 0
name="$(<"$MOCK_NAME_FILE")"
[[ ${#name} -le 63 ]] || { echo "reservation name exceeds 63 characters: $name" >&2; exit 1; }
[[ "$name" =~ ^[a-z]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "invalid reservation name: $name" >&2; exit 1; }
assert_file_contains "$MOCK_CALLS" '--require-specific-reservation'
record="$(find "$TMP" -maxdepth 1 -name 'reservations-*.txt' | head -1)"
json_log="${record%.txt}.jsonl"
assert_file_contains "$json_log" '"result":"success"'

touch "$record.lock"
run "$TMP/release_reservations.sh" --file "$record" --yes
assert_status 1
assert_output "reservation run is still active"
rm "$record.lock"

run "$TMP/release_reservations.sh" --file "$record" --yes
assert_status 0
assert_output "All recorded reservations were deleted"
assert_file_contains "$MOCK_CALLS" "compute reservations delete $name"

run "$TMP/grab_reservations.sh" --machine-type n2-highmem-64 --region us-central1 \
  --zones us-central1-a --delay 0 --max-delay 0 --count 1 --check-only
assert_status 0
assert_output "OK n2-highmem-64 in us-central1-a"

echo "script tests passed"
