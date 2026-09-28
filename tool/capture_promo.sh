#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
chrome_binary="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
promo_port="${PROMO_PORT:-$((20000 + ($$ % 20000)))}"
debug_port="${PROMO_DEBUG_PORT:-$((40000 + ($$ % 10000)))}"
output_dir="$project_dir/promo/screenshots"
profile_dir="$(mktemp -d)"
browser_pid=""

if [[ ! -x "$chrome_binary" ]]; then
  echo "Google Chrome wurde nicht unter $chrome_binary gefunden." >&2
  exit 1
fi

mkdir -p "$output_dir"
cd "$project_dir"
if [[ "${PROMO_SKIP_BUILD:-0}" != "1" ]]; then
  flutter build web --release -t lib/promo/promo_main.dart --base-href / --pwa-strategy=none
fi

python3 -m http.server "$promo_port" --directory build/web >/tmp/cat_snake_promo_server.log 2>&1 &
server_pid=$!

cleanup() {
  if [[ -n "$browser_pid" ]]; then
    kill "$browser_pid" >/dev/null 2>&1 || true
    wait "$browser_pid" >/dev/null 2>&1 || true
  fi
  kill "$server_pid" >/dev/null 2>&1 || true
  rm -rf "$profile_dir"
}
trap cleanup EXIT

sleep 0.2
if ! kill -0 "$server_pid" 2>/dev/null; then
  echo "Der lokale Promo-Server konnte auf Port $promo_port nicht starten." >&2
  cat /tmp/cat_snake_promo_server.log >&2
  exit 1
fi

for _ in {1..30}; do
  if curl -fsS "http://127.0.0.1:$promo_port/" >/dev/null; then
    break
  fi
  sleep 0.2
done

"$chrome_binary" \
  --headless=new \
  --no-first-run \
  --no-default-browser-check \
  --disable-dev-shm-usage \
  --hide-scrollbars \
  --remote-debugging-port="$debug_port" \
  --user-data-dir="$profile_dir" \
  about:blank \
  >/tmp/cat_snake_promo_chrome.log 2>&1 &
browser_pid=$!

node "$project_dir/tool/capture_promo.mjs" \
  "$debug_port" \
  "http://127.0.0.1:$promo_port" \
  "$output_dir"

echo "Promo-Screenshots wurden in $output_dir erzeugt."
