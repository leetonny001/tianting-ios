#!/usr/bin/env bash
# Builds and starts a real im-server in test mode for the iOS end-to-end tests. All secrets are random and live only in a
# temporary directory for this run; they are test-only, on this machine.
#   source scripts/e2e-server.sh      defines tt_server_start and tt_server_stop
# After tt_server_start: TT_E2E_HTTP, TT_E2E_ADMIN, TT_E2E_S3, TT_E2E_ADMIN_KEY, TT_E2E_CALLER, TT_E2E_SECRET, TT_E2E_DIR.
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
  # TT_E2E_TMP: where the server binary, database and logs go (default the system temporary directory).
  TT_E2E_DIR="$(mktemp -d "${TT_E2E_TMP:-${TMPDIR:-/tmp}}/tt-e2e.XXXXXX")"
  (cd "$dir" && go build -o "$TT_E2E_DIR/im-server" ./cmd/im-server) || return 1
  port="${TT_E2E_PORT:-18180}"
  admin_port="${TT_E2E_ADMIN_PORT:-18181}"
  local s3_port="${TT_E2E_S3_PORT:-18183}"
  for p in "$port" "$s3_port"; do
    if lsof -iTCP:"$p" -sTCP:LISTEN > /dev/null 2>&1; then
      echo "port $p is in use (a server left from an earlier run?)" >&2
      return 1
    fi
  done
  # Word list and reporting (C6): IM_MOD_ENABLED=1 (with a random test-only IM_REPORT_KEY); /v1/config then says
  # features.moderation=true. The caller has moderation.words (the word list API; tests add marker words only) and report.read
  # (the queue: a report from the app is there, AC-MOD-03-1).
  # Pin, notifications off and delete (C5): IM_CONV_SETTINGS_ENABLED=1, /v1/config then says features.convSettings=true.
  # Recall, quote and @ (C4): IM_MSG_ACTIONS_ENABLED=1 (needs IM_QUARANTINE_KEY, set below); /v1/config then says
  # features.msgActions=true. Images and files (C2): the fake S3 (scripts/fake_s3.py, 127.0.0.1 only; the simulator shares the Mac's network, so the
  # presigned http://127.0.0.1 addresses work as they are, NSAllowsLocalNetworking). Its credentials are fake values it does
  # not check, not real keys.
  python3 -I "$TT_REPO/scripts/fake_s3.py" --port "$s3_port" > "$TT_E2E_DIR/s3.log" 2>&1 &
  TT_E2E_S3_PID=$!
  for _ in $(seq 1 50); do
    curl -fs "http://127.0.0.1:$s3_port/__health" > /dev/null 2>&1 && break
    sleep 0.1
  done
  TT_E2E_ADMIN_KEY="$(openssl rand -hex 24)"
  TT_E2E_CALLER="ios-e2e"
  TT_E2E_SECRET="$(openssl rand -hex 24)"
  local b64 callers
  b64="$(printf '%s' "$TT_E2E_SECRET" | base64)"
  callers="$TT_E2E_DIR/callers.json"
  (umask 077; cat > "$callers" <<JSON
[{"id":"$TT_E2E_CALLER","alg":"hmac-sha256","secret":"$b64","scopes":["user.ban","msg.delete","mute.write","social.settings","social.friends","group.dissolve","group.write","push.user","push.all","account.invite","moderation.words","report.read"],"pushTypes":["notice","promo"]}]
JSON
  )
  IM_ADDR="127.0.0.1:$port" IM_ADMIN_ADDR="127.0.0.1:$admin_port" IM_METRICS_ADDR=off \
    IM_DB="$TT_E2E_DIR/im.db" IM_TEST_MODE=1 IM_DEMO_LOGIN=1 IM_V13_ADMIN_FEATURES=1 IM_PUSH_ENABLED=1 \
    IM_MSG_ACTIONS_ENABLED="${IM_MSG_ACTIONS_ENABLED:-1}" IM_CONV_SETTINGS_ENABLED="${IM_CONV_SETTINGS_ENABLED:-1}" \
    IM_MOD_ENABLED="${IM_MOD_ENABLED:-1}" IM_REPORT_KEY="$(openssl rand -base64 32)" \
    IM_REGISTER_MODE=invite IM_REFRESH_KEYS="e2e:$(openssl rand -hex 24)" IM_TEST_DISABLE_AUTH_LOCK=1 \
    IM_ADMIN_KEY="$TT_E2E_ADMIN_KEY" IM_JWT_SECRET="$(openssl rand -hex 24)" \
    IM_QUARANTINE_KEY="$(openssl rand -hex 24)" IM_ADMIN_CALLERS="$callers" \
    IM_FILES_ENABLED=1 IM_OBJSTORE_ENDPOINT="http://127.0.0.1:$s3_port" IM_OBJSTORE_REGION=us-east-1 \
    IM_OBJSTORE_BUCKET=chat IM_OBJSTORE_PUBLIC_BUCKET=avatars IM_OBJSTORE_PUBLIC_BASE_URL="http://127.0.0.1:$s3_port/avatars" \
    IM_OBJSTORE_ACCESS_KEY=ios-e2e-access IM_OBJSTORE_SECRET_KEY=ios-e2e-not-a-secret IM_UPLOAD_RATE="${IM_UPLOAD_RATE:-1000}" \
    "$TT_E2E_DIR/im-server" > "$TT_E2E_DIR/server.log" 2>&1 &
  TT_E2E_PID=$!
  TT_E2E_HTTP="http://localhost:$port"
  TT_E2E_ADMIN="http://127.0.0.1:$admin_port"
  TT_E2E_S3="http://127.0.0.1:$s3_port"
  for _ in $(seq 1 100); do
    curl -fs "http://127.0.0.1:$port/readyz" > /dev/null && break
    sleep 0.1
  done
  curl -fs "http://127.0.0.1:$port/readyz" > /dev/null || { cat "$TT_E2E_DIR/server.log"; return 1; }
  export TT_E2E_DIR TT_E2E_PID TT_E2E_S3_PID TT_E2E_HTTP TT_E2E_ADMIN TT_E2E_S3 TT_E2E_ADMIN_KEY TT_E2E_CALLER TT_E2E_SECRET
}

tt_server_stop() {
  [ -n "${TT_E2E_PID:-}" ] && kill "$TT_E2E_PID" 2> /dev/null
  [ -n "${TT_E2E_S3_PID:-}" ] && kill "$TT_E2E_S3_PID" 2> /dev/null
  [ -n "${TT_E2E_PID:-}" ] && wait "$TT_E2E_PID" 2> /dev/null
  [ -n "${TT_E2E_S3_PID:-}" ] && wait "$TT_E2E_S3_PID" 2> /dev/null
  [ -n "${TT_E2E_DIR:-}" ] && rm -rf "$TT_E2E_DIR"
  unset TT_E2E_PID TT_E2E_S3_PID TT_E2E_DIR
}
