#!/usr/bin/env bash
# tests/test-entrypoint-config-load-failure.sh
#
# Behavioural tests for the CONFIG_SVC config-load block in
# scripts/docker-entrypoint.sh (between the "BEGIN config-load" and
# "END config-load" markers).
#
# The real block is extracted from the entrypoint and run under `set -e`
# (as in the entrypoint) with stub `npx`, `timeout`, `sleep`, `node` and
# `exec` so nothing is re-implemented in the test. Contract:
#   - timeout (124), non-zero exit, or non-empty stdout without valid
#     `export` lines  -> [CONFIG] ERROR + loading-server failed state
#     (exec node /runner/loading-server.js error-page.html failed), and the
#     script never reaches the docroot/build phase
#   - auth failures print the refresh-app-config hint and are not retried
#   - not-found failures are not retried
#   - transient failures are retried (3 attempts) and can then succeed
#   - empty store (exit 0, empty stdout) is NOT a failure
#   - valid exports are eval'ed
#   - no CONFIG_SVC / no OSC_ACCESS_TOKEN -> block is skipped

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

block=$(awk '/^# BEGIN config-load/,/^# END config-load/' "$ENTRYPOINT")
if [ -z "$block" ]; then
  echo "FAIL: could not extract config-load block from $ENTRYPOINT"
  exit 1
fi

SB=$(mktemp -d)
export SB
mkdir -p "$SB/bin"
printf '%s\n' "$block" > "$SB/block.sh"

# npx stub: n-th call reads call<n>.exit / call<n>.out / call<n>.err
cat > "$SB/bin/npx" <<'EOF'
#!/bin/bash
n=$(cat "$SB/count" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$SB/count"
[ -f "$SB/call$n.out" ] && cat "$SB/call$n.out"
[ -f "$SB/call$n.err" ] && cat "$SB/call$n.err" >&2
code=0
[ -f "$SB/call$n.exit" ] && code=$(cat "$SB/call$n.exit")
exit "$code"
EOF
# timeout stub: drop the duration, run the command
cat > "$SB/bin/timeout" <<'EOF'
#!/bin/bash
shift
exec "$@"
EOF
cat > "$SB/bin/sleep" <<'EOF'
#!/bin/bash
echo "$@" >> "$SB/sleeps"
exit 0
EOF
cat > "$SB/bin/node" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$SB/bin/"*

# Harness: runs the block under set -e; `exec` is a function so the failed
# state is observable; REACHED_DOCROOT proves the build phase was reached.
cat > "$SB/harness.sh" <<'EOF'
#!/bin/bash
set -e
sleep 30 &
LOADING_PID=$!
export PATH="$SB/bin:$PATH"
OSAAS_CLI_VERSION=1.2.3
trap 'kill $LOADING_PID 2>/dev/null || true; echo TRAP_FIRED' EXIT
exec() { echo "EXEC_FAILED_STATE: $*"; trap - EXIT; kill $LOADING_PID 2>/dev/null || true; exit 42; }
source "$SB/block.sh"
echo "REACHED_DOCROOT"
echo "FOO=${FOO:-unset}"
trap - EXIT
kill $LOADING_PID 2>/dev/null || true
EOF

# run_case <name> ; env CONFIG_SVC / OSC_ACCESS_TOKEN come from caller
reset() { rm -f "$SB"/call* "$SB/count" "$SB/sleeps"; }
run() {
  OUT=$(CONFIG_SVC="${CONFIG_SVC-mystore}" OSC_ACCESS_TOKEN="${OSC_ACCESS_TOKEN-tok}" \
    bash "$SB/harness.sh" 2>&1)
  CODE=$?
  CALLS=$(cat "$SB/count" 2>/dev/null || echo 0)
}
expect_failed_state() {
  local name="$1"
  if [ "$CODE" -eq 42 ] && echo "$OUT" | grep -q 'EXEC_FAILED_STATE: node /runner/loading-server.js error-page.html failed' \
     && echo "$OUT" | grep -q '\[CONFIG\] ERROR' && ! echo "$OUT" | grep -q REACHED_DOCROOT; then
    pass "$name: [CONFIG] ERROR + failed state, build phase not reached"
  else
    fail "$name: expected failed state (code=$CODE)"; echo "$OUT"
  fi
}

# 1. non-zero exit, transient: retried 3 times then failed state
reset; echo 1 > "$SB/call1.exit"; echo 1 > "$SB/call2.exit"; echo 1 > "$SB/call3.exit"
echo "connection reset" > "$SB/call1.err"; echo "connection reset" > "$SB/call2.err"; echo "connection reset" > "$SB/call3.err"
run
expect_failed_state "non-zero exit"
[ "$CALLS" -eq 3 ] && pass "non-zero exit: 3 attempts" || fail "non-zero exit: expected 3 attempts, got $CALLS"
[ "$(wc -l < "$SB/sleeps")" -eq 2 ] && pass "non-zero exit: 3s backoff between attempts" || fail "backoff sleeps wrong"

# 2. timeout (124)
reset; for i in 1 2 3; do echo 124 > "$SB/call$i.exit"; done
run
expect_failed_state "timeout"
echo "$OUT" | grep -q 'timed out after 60s' && pass "timeout: reason names the timeout" || fail "timeout: reason missing"

# 3. garbled stdout, exit 0
reset; for i in 1 2 3; do echo "something went wrong" > "$SB/call$i.out"; done
run
expect_failed_state "no valid exports"
[ "$CALLS" -eq 3 ] && pass "no valid exports: retried to 3 attempts" || fail "no valid exports: attempts=$CALLS"

# 4. auth failure: hint printed, no retry
reset; echo 1 > "$SB/call1.exit"; echo "Error: token expired" > "$SB/call1.err"
run
expect_failed_state "auth failure"
echo "$OUT" | grep -q "refresh-app-config" && pass "auth failure: refresh-app-config hint printed" || fail "auth failure: hint missing"
[ "$CALLS" -eq 1 ] && pass "auth failure: not retried" || fail "auth failure: attempts=$CALLS"

# 5. not found: no retry, no hint
reset; echo 1 > "$SB/call1.exit"; echo "Error: instance not found" > "$SB/call1.err"
run
expect_failed_state "not found"
[ "$CALLS" -eq 1 ] && pass "not found: not retried" || fail "not found: attempts=$CALLS"
echo "$OUT" | grep -q "refresh-app-config" && fail "not found: hint should not print" || pass "not found: no token hint"

# 6. transient failure then success (passing path)
reset; echo 1 > "$SB/call1.exit"; echo "ECONNRESET" > "$SB/call1.err"
echo "export FOO=bar" > "$SB/call2.out"
run
if [ "$CODE" -eq 0 ] && echo "$OUT" | grep -q REACHED_DOCROOT && echo "$OUT" | grep -q 'FOO=bar' \
   && [ "$CALLS" -eq 2 ]; then
  pass "transient failure then success: continues with exports loaded"
else
  fail "transient then success (code=$CODE calls=$CALLS)"; echo "$OUT"
fi

# 7. success
reset; printf 'export FOO=bar\nexport BAZ=1\n' > "$SB/call1.out"
run
if [ "$CODE" -eq 0 ] && echo "$OUT" | grep -q 'Loaded 2 environment variable(s)' && echo "$OUT" | grep -q 'FOO=bar'; then
  pass "success: valid exports eval'ed and counted"
else
  fail "success path (code=$CODE)"; echo "$OUT"
fi

# 8. empty store: not a failure, no silent exit under set -e
reset
run
if [ "$CODE" -eq 0 ] && echo "$OUT" | grep -q "has no parameters" && echo "$OUT" | grep -q REACHED_DOCROOT; then
  pass "empty store: logs no-parameters line and continues"
else
  fail "empty store (code=$CODE)"; echo "$OUT"
fi

# 9. skip cases
reset
CONFIG_SVC="" run
if [ "$CODE" -eq 0 ] && [ "$CALLS" -eq 0 ] && echo "$OUT" | grep -q REACHED_DOCROOT; then
  pass "no CONFIG_SVC: block skipped"
else
  fail "no CONFIG_SVC (code=$CODE calls=$CALLS)"; echo "$OUT"
fi
reset
OSC_ACCESS_TOKEN="" run
if [ "$CODE" -eq 0 ] && [ "$CALLS" -eq 0 ] && echo "$OUT" | grep -q REACHED_DOCROOT; then
  pass "no OSC_ACCESS_TOKEN: block skipped"
else
  fail "no OSC_ACCESS_TOKEN (code=$CODE calls=$CALLS)"; echo "$OUT"
fi

# 11. secrets from stdout never reach the log (fake canary values only)
reset; echo "export DB_PASS='S3CR3T-canary'" > "$SB/call1.out"; echo 2 > "$SB/call1.exit"; echo boom > "$SB/call1.err"
for i in 2 3; do cp "$SB/call1.out" "$SB/call$i.out"; cp "$SB/call1.exit" "$SB/call$i.exit"; cp "$SB/call1.err" "$SB/call$i.err"; done
run
expect_failed_state "stdout leak, non-zero exit"
echo "$OUT" | grep -q 'exit code 2' && pass "non-zero exit: exit code printed" || fail "non-zero exit: exit code missing"
echo "$OUT" | grep -q 'S3CR3T-canary' && fail "non-zero exit: canary leaked" || pass "non-zero exit: canary absent from log"

reset; for i in 1 2 3; do echo "export MY-KEY='S3CR3T-canary'" > "$SB/call$i.out"; done
run
expect_failed_state "no valid export line"
echo "$OUT" | grep -q 'MY-KEY' && echo "$OUT" | grep -q 'values not logged' && pass "no valid export: key name and 'values not logged' shown" || fail "no valid export: diagnostic missing"
echo "$OUT" | grep -q 'S3CR3T-canary' && fail "no valid export: canary leaked" || pass "no valid export: canary absent from log"

reset; for i in 1 2 3; do echo 124 > "$SB/call$i.exit"; echo "export T_X='S3CR3T-canary'" > "$SB/call$i.out"; done
run
expect_failed_state "timeout with partial stdout"
echo "$OUT" | grep -q 'S3CR3T-canary' && fail "timeout: canary leaked" || pass "timeout: canary absent from log"

# 12. stderr is redacted: literal token, ghp_ token and JWT
JWT="eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.sig_abc-123"
GHP="ghp_abcdefghijklmnopqrstuvwxyz0123456789"
reset; echo 1 > "$SB/call1.exit"; echo "fail OSCTOKENLITERAL9 $GHP $JWT ECONNRESET" > "$SB/call1.err"
for i in 2 3; do cp "$SB/call1.exit" "$SB/call$i.exit"; cp "$SB/call1.err" "$SB/call$i.err"; done
OSC_ACCESS_TOKEN="OSCTOKENLITERAL9" run
expect_failed_state "stderr redaction"
if echo "$OUT" | grep -q '\[REDACTED\]' && ! echo "$OUT" | grep -q 'OSCTOKENLITERAL9' \
   && ! echo "$OUT" | grep -q "$GHP" && ! echo "$OUT" | grep -q "$JWT"; then
  pass "stderr: token, ghp_ and JWT redacted"
else
  fail "stderr redaction"; echo "$OUT"
fi

# 13. secret containing 'expired 401' on stdout does not change retry or hint
reset; for i in 1 2 3; do echo 1 > "$SB/call$i.exit"; echo "export X='expired 401'" > "$SB/call$i.out"; echo ECONNRESET > "$SB/call$i.err"; done
run
expect_failed_state "secret-dependent classifier"
[ "$CALLS" -eq 3 ] && pass "stdout content does not stop retries" || fail "classifier attempts=$CALLS"
echo "$OUT" | grep -q "refresh-app-config" && fail "stdout content triggered token hint" || pass "stdout content does not trigger token hint"

# 14. passing path: secret export still loaded, never logged
reset; printf "export FOO=bar\nexport SECRET_X='canary-ok'\n" > "$SB/call1.out"
run
if [ "$CODE" -eq 0 ] && echo "$OUT" | grep -q 'FOO=bar' && echo "$OUT" | grep -q 'Loaded 2 environment variable(s)' \
   && ! echo "$OUT" | grep -q 'canary-ok'; then
  pass "success: exports loaded, secret value not logged"
else
  fail "success with secret (code=$CODE)"; echo "$OUT"
fi

# 10. entrypoint documents the set -e / command substitution trap
if grep -q 'set -e' "$ENTRYPOINT" && echo "$block" | grep -q 'x=\$(cmd)'; then
  pass "block documents the set -e / x=\$(cmd) pitfall"
else
  fail "set -e comment missing"
fi

rm -rf "$SB"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
