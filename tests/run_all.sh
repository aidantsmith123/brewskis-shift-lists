#!/bin/bash
# Run every browser test against the local test server, each on the database setup it expects.
# Needs: the test Postgres on /var/tmp:54329 and fake_postgrest.py serving the site on :8099.
# Usage: bash run_all.sh [out-dir]
cd "$(dirname "$0")"
OUT=${1:-/tmp/brewskis-e2e}; mkdir -p "$OUT"
declare -A SETUP=(
  [e2e]=reset [e2e_versions]=reset [e2e_taps]=reset [e2e_supfilter]=reset
  [e2e_v8]=v8 [e2e_listsup]=v8
)
SUITES="e2e e2e_tasks e2e_sched e2e_sides e2e_sound e2e_schedule e2e_events e2e_repeat e2e_promote e2e_parties e2e_cash e2e_dailycash e2e_alerts e2e_settings e2e_push e2e_versions e2e_sup e2e_supfilter e2e_listsup e2e_v8 e2e_taps e2e_live"
pass=0; fail=0; failed=""
for t in $SUITES; do
  case "${SETUP[$t]:-v22}" in
    reset) bash reset_db.sh >/dev/null 2>&1 ;;
    v8)    bash reset_db.sh >/dev/null 2>&1; psql -h /var/tmp -p 54329 -U postgres -d bk -q -f fixtures/v8_state.sql >/dev/null 2>&1 ;;
    v22)   bash setup_v22.sh >/dev/null 2>&1 ;;
  esac
  if timeout 300 python3 "$t.py" "$OUT" > "$OUT/$t.log" 2>&1; then pass=$((pass+1)); echo "pass  $t"
  else fail=$((fail+1)); failed="$failed $t"; echo "FAIL  $t  (see $OUT/$t.log)"; fi
done
echo "--- $pass passed, $fail failed${failed:+:$failed}"
[ $fail -eq 0 ]
