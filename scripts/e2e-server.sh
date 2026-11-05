#!/usr/bin/env bash
# Builds and starts a real im-server in test mode for the iOS end-to-end tests. All secrets are random and live only in a
# temporary directory for this run; they are test-only, on this machine.
#   source scripts/e2e-server.sh      defines tt_server_start and tt_server_stop
# After tt_server_start: TT_E2E_HTTP, TT_E2E_ADMIN, TT_E2E_ADMIN_KEY, TT_E2E_CALLER, TT_E2E_SECRET, TT_E2E_DIR.
TT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tt_server_dir() {
  if [ -n "${TIANTING_SERVER_DIR:-}" ]; then echo "$TIANTING_SERVER_DIR"; return; fi
  for d in "$TT_REPO/../tianting-server/server" "$TT_REPO/../im-mvp/server"; do
    if [ -d "$d/cmd/im-server" ]; then echo "$d"; return; fi
  done
  echo "no im-server source: set TIANTING_SERVER_DIR" >&2
  return 1
}

tt_server_start() {
  local dir port admin_port
  dir="$(tt_server_dir)" || return 1
  TT_E2E_DIR="$(mktemp -d)"
  (cd "$dir" && go build -o "$TT_E2E_DIR/im-server" ./cmd/im-server) || return 1
  port="${TT_E2E_PORT:-18180}"
  admin_port="${TT_E2E_ADMIN_PORT:-18181}"
  if lsof -iTCP:"$port" -sTCP:LISTEN > /dev/null 2>&1; then
    echo "port $port is in use (a server left from an earlier run?)" >&2
    return 1
  fi
  TT_E2E_ADMIN_KEY="$(openssl rand -hex 24)"
  TT_E2E_CALLER="ios-e2e"
  TT_E2E_SECRET="$(openssl rand -hex 24)"
  local b64 callers
  b64="$(printf '%s' "$TT_E2E_SECRET" | base64)"
  callers="$TT_E2E_DIR/callers.json"
  (umask 077; cat > "$callers" <<JSON
[{"id":"$TT_E2E_CALLER","alg":"hmac-sha256","secret":"$b64","scopes":["user.ban","msg.delete","mute.write","social.settings","social.friends","group.dissolve","group.write"]}]
JSON
  )
  IM_ADDR="127.0.0.1:$port" IM_ADMIN_ADDR="127.0.0.1:$admin_port" IM_METRICS_ADDR=off \
    IM_DB="$TT_E2E_DIR/im.db" IM_TEST_MODE=1 IM_DEMO_LOGIN=1 IM_V13_ADMIN_FEATURES=1 \
    IM_ADMIN_KEY="$TT_E2E_ADMIN_KEY" IM_JWT_SECRET="$(openssl rand -hex 24)" \
    IM_QUARANTINE_KEY="$(openssl rand -hex 24)" IM_ADMIN_CALLERS="$callers" \
    "$TT_E2E_DIR/im-server" > "$TT_E2E_DIR/server.log" 2>&1 &
  TT_E2E_PID=$!
  TT_E2E_HTTP="http://localhost:$port"
  TT_E2E_ADMIN="http://127.0.0.1:$admin_port"
  for _ in $(seq 1 100); do
    curl -fs "http://127.0.0.1:$port/readyz" > /dev/null && break
    sleep 0.1
  done
  curl -fs "http://127.0.0.1:$port/readyz" > /dev/null || { cat "$TT_E2E_DIR/server.log"; return 1; }
  export TT_E2E_DIR TT_E2E_PID TT_E2E_HTTP TT_E2E_ADMIN TT_E2E_ADMIN_KEY TT_E2E_CALLER TT_E2E_SECRET
}

tt_server_stop() {
  [ -n "${TT_E2E_PID:-}" ] && kill "$TT_E2E_PID" 2> /dev/null
  [ -n "${TT_E2E_DIR:-}" ] && rm -rf "$TT_E2E_DIR"
  unset TT_E2E_PID TT_E2E_DIR
}
