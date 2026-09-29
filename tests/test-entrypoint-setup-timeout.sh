#!/usr/bin/env bash
# tests/test-entrypoint-setup-timeout.sh
#
# Shell regression tests for the setup.sh timeout fix in
# scripts/docker-entrypoint.sh.
#
# Background:
#   The "setup.sh escape hatch" block ran an optional repo-provided
#   setup.sh with no timeout and no failure handling:
#       (cd "$BUILD_DIR" && ./setup.sh)
#   If setup.sh never exited, the entrypoint blocked forever: the app
#   stayed in `Build Status: building` indefinitely, /healthz never
#   resolved, and wait-for-app-ready timed out repeatedly with no
#   terminal signal. A non-zero exit from setup.sh also propagated
#   through `set -e` without ever reaching the error-page mechanism
#   used by the docroot-missing and composer-install-failure checks.
#
# Fix (this PR):
#   Wrap the invocation with `timeout 300s`, capture the exit code, and
#   treat both a timeout (124) and any other non-zero exit as a terminal
#   build failure: kill the loading server and
#   `exec node /runner/loading-server.js error-page.html failed`,
#   matching the existing docroot-missing / composer-install-failure
#   pattern in the same file.
#
# These tests grep the entrypoint to assert the fix has not regressed,
# and run the extracted shell logic in a sandbox to verify the actual
# timeout/exit-code behavior.

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: setup.sh invocation is wrapped with `timeout`
# ---------------------------------------------------------------------------
if grep -qE 'timeout [0-9]+s \./setup\.sh' "$ENTRYPOINT"; then
  pass "setup.sh invocation is wrapped with timeout"
else
  fail "setup.sh invocation is not wrapped with timeout"
fi

# ---------------------------------------------------------------------------
# Test 2: the setup.sh block checks for exit code 124 (timeout)
# ---------------------------------------------------------------------------
block=$(awk '/setup\.sh escape hatch/,/^fi$/' "$ENTRYPOINT")
if echo "$block" | grep -qE '\$setup_exit -eq 124'; then
  pass "setup.sh block checks for timeout exit code 124"
else
  fail "setup.sh block does not check for timeout exit code 124"
fi

# ---------------------------------------------------------------------------
# Test 3: the setup.sh block checks for any other non-zero exit
# ---------------------------------------------------------------------------
if echo "$block" | grep -qE '\$setup_exit -ne 0'; then
  pass "setup.sh block checks for non-zero (non-timeout) exit code"
else
  fail "setup.sh block does not check for non-zero exit code"
fi

# ---------------------------------------------------------------------------
# Test 4: both the timeout and failure branches reach the terminal
# error-page mechanism (kill loading server + exec error-page.html failed)
# ---------------------------------------------------------------------------
error_exec_count=$(echo "$block" | grep -c 'error-page.html failed')
kill_count=$(echo "$block" | grep -c 'kill \$LOADING_PID')
if [ "$error_exec_count" -ge 2 ] && [ "$kill_count" -ge 2 ]; then
  pass "both timeout and failure branches kill the loading server and exec the error page"
else
  fail "expected 2 terminal-failure branches (timeout + non-zero exit), found error_exec=$error_exec_count kill=$kill_count"
fi

# ---------------------------------------------------------------------------
# Test 5: behavioral verification — a hanging setup.sh is killed by the
# timeout and produces exit code 124, not an indefinite hang
# ---------------------------------------------------------------------------
sandbox_dir=$(mktemp -d)
cat > "$sandbox_dir/setup.sh" <<'EOF'
#!/bin/bash
sleep 30
EOF
chmod +x "$sandbox_dir/setup.sh"

start_ts=$(date +%s)
sandbox_timeout_exit=$(bash -c "
  cd '$sandbox_dir'
  setup_exit=0
  (timeout 1s ./setup.sh) || setup_exit=\$?
  echo \"\$setup_exit\"
")
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))

if [ "$sandbox_timeout_exit" -eq 124 ] && [ "$elapsed" -lt 10 ]; then
  pass "a hanging setup.sh is killed by timeout and reports exit 124 (elapsed ${elapsed}s)"
else
  fail "hanging setup.sh did not time out as expected (exit=$sandbox_timeout_exit elapsed=${elapsed}s)"
fi

# ---------------------------------------------------------------------------
# Test 6: behavioral verification — a setup.sh that fails fast (non-zero,
# non-timeout exit) reports its real exit code, not 124
# ---------------------------------------------------------------------------
cat > "$sandbox_dir/setup.sh" <<'EOF'
#!/bin/bash
exit 3
EOF
chmod +x "$sandbox_dir/setup.sh"

sandbox_fail_exit=$(bash -c "
  cd '$sandbox_dir'
  setup_exit=0
  (timeout 5s ./setup.sh) || setup_exit=\$?
  echo \"\$setup_exit\"
")

if [ "$sandbox_fail_exit" -eq 3 ]; then
  pass "a fast-failing setup.sh reports its real exit code (3), distinguishable from a timeout"
else
  fail "fast-failing setup.sh reported unexpected exit code: $sandbox_fail_exit"
fi

# ---------------------------------------------------------------------------
# Test 7: behavioral verification — a well-behaved setup.sh still succeeds
# (exit 0) and does not trip the timeout/failure branches
# ---------------------------------------------------------------------------
cat > "$sandbox_dir/setup.sh" <<'EOF'
#!/bin/bash
echo "setting up"
exit 0
EOF
chmod +x "$sandbox_dir/setup.sh"

sandbox_ok_exit=$(bash -c "
  cd '$sandbox_dir'
  setup_exit=0
  (timeout 300s ./setup.sh) >/dev/null || setup_exit=\$?
  echo \"\$setup_exit\"
")

if [ "$sandbox_ok_exit" -eq 0 ]; then
  pass "a well-behaved setup.sh still succeeds (exit 0) with the timeout wrapper in place"
else
  fail "well-behaved setup.sh unexpectedly failed: $sandbox_ok_exit"
fi

rm -rf "$sandbox_dir"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  exit 1
fi
exit 0
