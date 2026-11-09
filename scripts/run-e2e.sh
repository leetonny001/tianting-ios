#!/usr/bin/env bash
# Runs the XCUITest end-to-end suite on a simulator against a real im-server, then checks what the run left behind:
# os_log has no message marker or token (AC-UI-90-12), UserDefaults has only ui.* app keys (AC-UI-90-2), and the app's data
# directory has no deleted original text.
#   scripts/run-e2e.sh [--device "name or udid"] [--only ChatE2ETests[/testName]] [--screenshots dir]
# TT_E2E_EXTERNAL=1: use a server that is already running (FE-640 cross-platform tests: the three platforms take turns on one
#   server). TT_E2E_HTTP, TT_E2E_ADMIN, TT_E2E_S3, TT_E2E_ADMIN_KEY, TT_E2E_CALLER, TT_E2E_SECRET and TT_E2E_DIR (its
#   server.log is checked afterwards) must be set; the server is not stopped. TT_E2E_XP, TT_E2E_XP_FROM go to the tests.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE="TT iPhone 18 Pro"
ONLY=()
SHOTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --only) ONLY+=("-only-testing:TiantingUITests/$2"); shift 2 ;;
    --screenshots) SHOTS="$2"; shift 2 ;;
    *) echo "unknown argument $1"; exit 2 ;;
  esac
done

if ! xcrun simctl list devices | grep -q "$DEVICE"; then
  echo "no simulator named $DEVICE: create one with xcrun simctl create" >&2
  exit 2
fi
UDID="$(xcrun simctl list devices | grep "$DEVICE" | grep -v unavailable | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
xcrun simctl bootstatus "$UDID" -b > /dev/null

if [ "${TT_E2E_EXTERNAL:-0}" = "1" ]; then
  for v in TT_E2E_HTTP TT_E2E_ADMIN TT_E2E_S3 TT_E2E_ADMIN_KEY TT_E2E_CALLER TT_E2E_SECRET TT_E2E_DIR; do
    [ -n "${!v:-}" ] || { echo "TT_E2E_EXTERNAL=1 needs $v" >&2; exit 2; }
  done
  trap 'rm -rf "$TT_E2E_DIR/control"' EXIT
else
  source "$REPO/scripts/e2e-server.sh"
  tt_server_start || exit 1
  trap tt_server_stop EXIT
fi

# Tests ask for a system appearance by writing $TT_E2E_DIR/control/appearance (light or dark).
mkdir -p "$TT_E2E_DIR/control"
(
  while [ -d "$TT_E2E_DIR/control" ]; do
    f="$TT_E2E_DIR/control/appearance"
    if [ -f "$f" ]; then
      xcrun simctl ui "$UDID" appearance "$(cat "$f")"
      rm -f "$f"
    fi
    sleep 0.2
  done
) &
xcrun simctl ui "$UDID" appearance light

STARTED="$(date '+%Y-%m-%d %H:%M:%S')"
DERIVED="${TT_DERIVED_DATA:-$REPO/build/e2e}"
mkdir -p "$DERIVED"
RESULT="$DERIVED/result-$(date +%s).xcresult"
TEST_RUNNER_TT_E2E_HTTP="$TT_E2E_HTTP" TEST_RUNNER_TT_E2E_ADMIN="$TT_E2E_ADMIN" \
  TEST_RUNNER_TT_E2E_S3="$TT_E2E_S3" TEST_RUNNER_TT_E2E_ADMIN_KEY="$TT_E2E_ADMIN_KEY" TEST_RUNNER_TT_E2E_CALLER="$TT_E2E_CALLER" \
  TEST_RUNNER_TT_E2E_SECRET="$TT_E2E_SECRET" TEST_RUNNER_TT_E2E_SCREENSHOTS="$SHOTS" \
  TEST_RUNNER_TT_E2E_CONTROL="$TT_E2E_DIR/control" \
  TEST_RUNNER_TT_E2E_XP="${TT_E2E_XP:-}" TEST_RUNNER_TT_E2E_XP_FROM="${TT_E2E_XP_FROM:-}" \
  xcodebuild test -project "$REPO/Tianting.xcodeproj" -scheme Tianting -destination "id=$UDID" \
  -derivedDataPath "$DERIVED" -resultBundlePath "$RESULT" -parallel-testing-enabled NO -collect-test-diagnostics never \
  ${ONLY[@]+"${ONLY[@]}"} 2>&1 | tee "$DERIVED/last.log" \
  | grep --line-buffered -E "Test Case .* (passed|failed)|error:|Executed|\*\* TEST|Testing failed|E2E-LOST-TAP"
STATUS=${PIPESTATUS[0]}

python3 -I "$REPO/scripts/py/check_e2e_leftovers.py" "$UDID" "$STARTED" "$TT_E2E_DIR/server.log"
CHECK=$?
echo "results: $RESULT"
[ "$STATUS" -eq 0 ] && [ "$CHECK" -eq 0 ]
