#!/bin/sh
set -eu

log_file="$(mktemp)"
response_file="$(mktemp)"
server_pid=""

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -f "$log_file" "$response_file"
}
trap cleanup EXIT INT TERM

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
HOST=127.0.0.1 PORT="$port" GUILE_AUTO_COMPILE=0 \
  ./bloom-filter-saturation-lab >"$log_file" 2>&1 &
server_pid=$!

attempt=0
until curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 50 ]; then
    cat "$log_file" >&2
    exit 1
  fi
  sleep 0.1
done

test "$(curl -fsS "http://127.0.0.1:$port/healthz")" = "ok"
curl -fsS "http://127.0.0.1:$port/" | grep -q "PROBABLY PRESENT"
curl -fsS "http://127.0.0.1:$port/styles.css" | grep -q -- "--signal"
curl -fsS "http://127.0.0.1:$port/app.js" | grep -q "renderStrategies"

curl -fsS \
  "http://127.0.0.1:$port/api/simulate?candidates_per_second=999999&run_seconds=20&seed=77" \
  >"$response_file"
jq -e \
  '.config.candidatesPerSecond == 100000 and .config.runSeconds == 20 and (.strategies | length) == 4' \
  "$response_file" >/dev/null
jq -e \
  '.strategies[] | select(.policy == "fixed_definitive") | .metrics.falsePositives >= 0' \
  "$response_file" >/dev/null

status="$(curl -sS -o "$response_file" -w '%{http_code}' \
  -X POST "http://127.0.0.1:$port/api/simulate")"
test "$status" = "405"
jq -e '.error == "method not allowed"' "$response_file" >/dev/null

status="$(curl -sS -o "$response_file" -w '%{http_code}' \
  "http://127.0.0.1:$port/nope")"
test "$status" = "404"

if HOST=public.example PORT="$port" GUILE_AUTO_COMPILE=0 \
  ./bloom-filter-saturation-lab >/dev/null 2>&1; then
  echo "server accepted an invalid HOST" >&2
  exit 1
fi

echo "server_test: all assertions passed"
