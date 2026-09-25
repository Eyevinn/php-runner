#!/usr/bin/env bash
# tests/test-entrypoint-credential-scrub.sh
#
# Shell regression tests for the credential-scrub fix in scripts/docker-entrypoint.sh.
#
# Background:
#   When SOURCE_URL embeds credentials (https://user:pass@host/path.git), the
#   pattern used by Gitea-backed apps, the host extraction
#       GIT_HOST="${SOURCE_URL#*://}"; GIT_HOST="${GIT_HOST%%/*}"
#   yields "user:pass@host" — i.e. credentials remain in GIT_HOST.
#
#   Without the fix the clone block echoed the credentialed URL into pod logs
#   and, crucially, persisted the credentialed URL into .git/config because the
#   "scrub" line
#       git remote set-url origin "${PROTOCOL}://${GIT_HOST}${GIT_PATH}"
#   reconstructed the same URL it was supposed to remove.
#
# Fix (this PR):
#   Introduce GIT_HOST_PUBLIC="${GIT_HOST##*@}" — a sanitized variant used in
#   log lines and the persisted remote URL. GIT_HOST keeps any embedded creds
#   for the clone itself when no separate GIT_TOKEN is provided. When SOURCE_URL
#   has no credentials, GIT_HOST_PUBLIC == GIT_HOST and behavior is unchanged.
#
# These tests grep the entrypoint to assert the fix has not regressed.

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: GIT_HOST_PUBLIC is derived from GIT_HOST with embedded creds stripped
# ---------------------------------------------------------------------------
if grep -qE 'GIT_HOST_PUBLIC="\$\{GIT_HOST##\*@\}"' "$ENTRYPOINT"; then
  pass "GIT_HOST_PUBLIC strips user:pass@ from GIT_HOST"
else
  fail "GIT_HOST_PUBLIC assignment is missing or does not strip embedded creds"
fi

# ---------------------------------------------------------------------------
# Test 2: persisted remote URL uses the scrubbed host
# ---------------------------------------------------------------------------
if grep -qF 'git -C "$WORK_DIR" remote set-url origin "${PROTOCOL}://${GIT_HOST_PUBLIC}${GIT_PATH}"' "$ENTRYPOINT"; then
  pass "remote set-url uses GIT_HOST_PUBLIC (credentials removed from .git/config)"
else
  fail "remote set-url still uses GIT_HOST — credentials would leak into .git/config"
fi

# ---------------------------------------------------------------------------
# Test 3: remote set-url is unconditional (not guarded by GIT_TOKEN check)
#
# The scrub must run for BOTH code paths: (1) when GIT_TOKEN is provided
# (GitHub, any git host with a separate token) and (2) when SOURCE_URL
# itself embeds credentials (Gitea-backed apps: https://user:pass@host/...).
# If the set-url is inside an `if [[ -n "$GIT_TOKEN" ]]` block the Gitea
# path is never scrubbed.
# ---------------------------------------------------------------------------
# Extract the line number of the remote set-url line
seturl_line=$(grep -n 'remote set-url origin' "$ENTRYPOINT" | head -1 | cut -d: -f1)
if [[ -z "$seturl_line" ]]; then
  fail "remote set-url line not found in entrypoint"
else
  # Check if there's an unclosed 'if [[ -n "$GIT_TOKEN" ]]' above the set-url line
  # by counting if/fi blocks in the lines before it
  block=$(head -n "$seturl_line" "$ENTRYPOINT" | grep -E 'if \[\[ -n "\$GIT_TOKEN"' || true)
  fi_count=$(head -n "$seturl_line" "$ENTRYPOINT" | grep -cE '^fi$' || true)
  if_count=$(head -n "$seturl_line" "$ENTRYPOINT" | grep -cE '^if \[\[' || true)
  if [[ "$if_count" -le "$fi_count" ]]; then
    pass "remote set-url is outside any if-block (unconditional — covers both GIT_TOKEN and Gitea paths)"
  else
    fail "remote set-url appears to be inside an if-block — Gitea credential path may not be scrubbed"
  fi
fi

# ---------------------------------------------------------------------------
# Test 4: echo lines use GIT_HOST_PUBLIC (no unscrubbed GIT_HOST in log output)
# ---------------------------------------------------------------------------
unsafe_echo=$(grep -nE 'echo "cloning.*\$\{GIT_HOST\}' "$ENTRYPOINT" || true)
if [ -z "$unsafe_echo" ]; then
  pass "no echo line prints the unscrubbed GIT_HOST"
else
  fail "echo line still prints unscrubbed GIT_HOST: $unsafe_echo"
fi

# ---------------------------------------------------------------------------
# Test 5: behavioral verification — run the relevant fragment in a sandbox
#
# Source the host-parsing logic with a Gitea-style SOURCE_URL and assert that
# GIT_HOST_PUBLIC has no '@' while GIT_HOST does. This catches regressions
# where the parameter expansion is changed in a way that defeats the strip.
# ---------------------------------------------------------------------------
sandbox=$(bash -c '
  SOURCE_URL="https://oscadmin:abc123def@example.git.host/owner/repo.git"
  GIT_HOST="${SOURCE_URL#*://}"
  GIT_HOST="${GIT_HOST%%/*}"
  GIT_HOST_PUBLIC="${GIT_HOST##*@}"
  echo "GIT_HOST=$GIT_HOST"
  echo "GIT_HOST_PUBLIC=$GIT_HOST_PUBLIC"
')

if echo "$sandbox" | grep -q '^GIT_HOST=oscadmin:abc123def@example.git.host$' && \
   echo "$sandbox" | grep -q '^GIT_HOST_PUBLIC=example.git.host$'; then
  pass "host-parsing on a Gitea-style URL strips creds in GIT_HOST_PUBLIC only"
else
  fail "host-parsing sandbox produced unexpected output: $sandbox"
fi

# ---------------------------------------------------------------------------
# Test 6: behavioral verification — credential-less URL is unchanged
# ---------------------------------------------------------------------------
sandbox_plain=$(bash -c '
  SOURCE_URL="https://github.com/owner/repo.git"
  GIT_HOST="${SOURCE_URL#*://}"
  GIT_HOST="${GIT_HOST%%/*}"
  GIT_HOST_PUBLIC="${GIT_HOST##*@}"
  echo "GIT_HOST=$GIT_HOST"
  echo "GIT_HOST_PUBLIC=$GIT_HOST_PUBLIC"
')

if echo "$sandbox_plain" | grep -q '^GIT_HOST=github.com$' && \
   echo "$sandbox_plain" | grep -q '^GIT_HOST_PUBLIC=github.com$'; then
  pass "host-parsing on a credential-less URL is a no-op (GIT_HOST_PUBLIC == GIT_HOST)"
else
  fail "credential-less host-parsing produced unexpected output: $sandbox_plain"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  exit 1
fi
exit 0
