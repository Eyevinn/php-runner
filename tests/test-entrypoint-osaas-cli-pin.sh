#!/usr/bin/env bash
# tests/test-entrypoint-osaas-cli-pin.sh
#
# The @osaas/cli version used by the entrypoint is pinned once, in the
# Dockerfile (ENV OSAAS_CLI_VERSION), and read by scripts/docker-entrypoint.sh.

ENTRYPOINT="scripts/docker-entrypoint.sh"
DOCKERFILE="Dockerfile"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Test 1: no unpinned @osaas/cli reference remains
if grep -rn '@osaas/cli@latest' scripts Dockerfile* >/dev/null; then
  fail "an unpinned @osaas/cli@latest reference remains"
else
  pass "no @osaas/cli@latest reference in scripts or Dockerfile"
fi

# Test 2: the version is defined exactly once, as an exact x.y.z
if [ "$(grep -cE '^ENV OSAAS_CLI_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$DOCKERFILE")" -eq 1 ]; then
  pass "Dockerfile pins OSAAS_CLI_VERSION to an exact version once"
else
  fail "Dockerfile does not pin OSAAS_CLI_VERSION exactly once"
fi

# Test 3: every npx call of @osaas/cli uses the variable
total=$(grep -c 'npx.*@osaas/cli@' "$ENTRYPOINT")
using=$(grep -c 'npx.*@osaas/cli@\${OSAAS_CLI_VERSION:?' "$ENTRYPOINT")
if [ "$total" -ge 1 ] && [ "$total" -eq "$using" ]; then
  pass "every npx @osaas/cli call uses OSAAS_CLI_VERSION"
else
  fail "npx calls: $total, using OSAAS_CLI_VERSION: $using"
fi

# Tests 4 and 5 (behaviour): run the expansion used in the entrypoint
expr=$(grep -o '"@osaas/cli@\${OSAAS_CLI_VERSION:?[^}]*}"' "$ENTRYPOINT" | head -1)
if [ -n "$expr" ]; then
  if (unset OSAAS_CLI_VERSION; eval "echo $expr") >/dev/null 2>&1; then
    fail "unset OSAAS_CLI_VERSION did not fail"
  else
    pass "unset OSAAS_CLI_VERSION fails"
  fi
  got=$(OSAAS_CLI_VERSION=1.2.3 bash -c "echo $expr")
  if [ "$got" = "@osaas/cli@1.2.3" ]; then
    pass "pinned version is the one passed to npx"
  else
    fail "unexpected package spec: $got"
  fi
else
  fail "could not extract the version expansion from the entrypoint"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  exit 1
fi
exit 0
