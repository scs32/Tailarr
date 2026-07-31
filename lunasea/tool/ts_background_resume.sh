#!/usr/bin/env bash
# Run the embedded-Tailscale background/resume robustness test on the iOS
# simulator while streaming the embedded tailscaled logs off the device and
# grepping them for the "ReceiveIPv4 not running" / magicsock symptom.
#
# The Dart integration test (integration_test/tailscale_background_resume_test.dart)
# drives the lifecycle transitions and asserts the tunnel recovers; this wrapper
# adds the native-log evidence the Dart side can't see.
#
# Usage:
#   TS_AUTHKEY=tskey-auth-... ./tool/ts_background_resume.sh [sim-udid] [server-host]
#
# Defaults: sim = e2e-iphone, server = https://tailarr.tail074f8b.ts.net
set -uo pipefail

SIM="${1:-C8FA7CB6-08A8-4597-B135-4AB2E393C5DC}"
SERVER_HOST="${2:-https://tailarr.tail074f8b.ts.net}"
: "${TS_AUTHKEY:?set TS_AUTHKEY to a tskey-auth- enrollment key}"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

STAMP="$(date +%Y%m%d-%H%M%S)"
LOGDIR="${TMPDIR:-/tmp}/ts-bg-resume-$STAMP"
mkdir -p "$LOGDIR"
NATIVE_LOG="$LOGDIR/tailscaled-native.log"
TEST_LOG="$LOGDIR/flutter-test.log"

echo "== ts background/resume robustness run =="
echo "sim=$SIM server=$SERVER_HOST"
echo "logs -> $LOGDIR"

# Make sure the sim is booted.
xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || xcrun simctl boot "$SIM" 2>/dev/null
xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1

# Stream the Runner process's unified log (embedded tsnet/magicsock logs land
# here on iOS). Started before the test, killed after.
echo "== starting native log stream =="
xcrun simctl spawn "$SIM" log stream \
  --level debug \
  --predicate 'process == "Runner" OR processImagePath CONTAINS "Runner"' \
  > "$NATIVE_LOG" 2>&1 &
LOG_PID=$!
sleep 2

cleanup() { kill "$LOG_PID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== running integration test =="
set -o pipefail
flutter test integration_test/tailscale_background_resume_test.dart \
  -d "$SIM" \
  --dart-define=TS_AUTHKEY="$TS_AUTHKEY" \
  --dart-define=SERVER_HOST="$SERVER_HOST" \
  2>&1 | tee "$TEST_LOG"
TEST_RC=${PIPESTATUS[0]}

sleep 2
cleanup
trap - EXIT

echo
echo "== native-log symptom scan ($NATIVE_LOG) =="
if grep -iE 'receiveipv4|receiveipv6|magicsock|rebind|re-?stun|ReceiveFunc|BindUpdate|not running' "$NATIVE_LOG" ; then
  echo "  ^ magicsock/receive-path activity captured above"
else
  echo "  (no magicsock/receiveipv4/rebind lines seen in native log)"
fi

echo
echo "== dart-side warning scan ($TEST_LOG) =="
grep -iE 'receiveWarning=true|SURFACED|receiveipv4|did NOT recover|RESTART FIRED|SUCCESS —' "$TEST_LOG" || echo "  (no dart warning markers)"

echo
echo "test exit code: $TEST_RC"
echo "artifacts: $LOGDIR"
exit "$TEST_RC"
