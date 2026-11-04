#!/bin/bash
set -e

PORT=${PORT:-8080}
WORK_DIR="/usercontent/app"

# Start loading server to show build status
node /runner/loading-server.js &
LOADING_PID=$!

cleanup() {
  kill $LOADING_PID 2>/dev/null || true
}
trap cleanup EXIT

# Write commit metadata to a well-known file for platform visibility
write_commit_info() {
  local repo_dir="$1"
  if [ -d "$repo_dir/.git" ]; then
    local sha shortSha msg author date recentCommits
    sha=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null) || return 0
    shortSha=$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null) || return 0
    msg=$(git -C "$repo_dir" log -1 --format='%s' 2>/dev/null) || return 0
    author=$(git -C "$repo_dir" log -1 --format='%an' 2>/dev/null) || return 0
    date=$(git -C "$repo_dir" log -1 --format='%aI' 2>/dev/null) || return 0
    recentCommits=$(git -C "$repo_dir" log -5 --format='%H' 2>/dev/null | while read -r c_sha; do
      jq -n \
        --arg sha "$c_sha" \
        --arg shortSha "$(git -C "$repo_dir" rev-parse --short "$c_sha" 2>/dev/null)" \
        --arg message "$(git -C "$repo_dir" log -1 --format='%s' "$c_sha" 2>/dev/null)" \
        --arg author "$(git -C "$repo_dir" log -1 --format='%an' "$c_sha" 2>/dev/null)" \
        --arg date "$(git -C "$repo_dir" log -1 --format='%aI' "$c_sha" 2>/dev/null)" \
        '{sha:$sha,shortSha:$shortSha,message:$message,author:$author,date:$date}'
    done | jq -s '.' 2>/dev/null) || recentCommits='[]'
    jq -n \
      --arg sha "$sha" \
      --arg shortSha "$shortSha" \
      --arg message "$msg" \
      --arg author "$author" \
      --arg date "$date" \
      --argjson recentCommits "$recentCommits" \
      '{sha:$sha,shortSha:$shortSha,message:$message,author:$author,date:$date,recentCommits:$recentCommits}' \
      > "$repo_dir/.commit-info.json" 2>/dev/null || true
    echo "Commit info: $(jq -r '.shortSha + " - " + .message' "$repo_dir/.commit-info.json" 2>/dev/null || echo 'unavailable')"
  fi
}

# ---- Clone phase ----
SOURCE_URL="${SOURCE_URL:-$GITHUB_URL}"
if [[ -z "$SOURCE_URL" ]]; then
  echo "ERROR: SOURCE_URL (or GITHUB_URL) is required" >&2
  kill $LOADING_PID 2>/dev/null || true
  exec node /runner/loading-server.js error-page.html failed
fi

# Extract branch from URL fragment
BRANCH=""
if [[ "$SOURCE_URL" == *"#"* ]]; then
  BRANCH="${SOURCE_URL#*#}"
  SOURCE_URL="${SOURCE_URL%%#*}"
fi

# Always parse host, path, and protocol from SOURCE_URL so that they are
# available for the credential-scrub step regardless of which auth path is taken.
GIT_HOST="${SOURCE_URL#*://}"   # strip scheme
GIT_HOST="${GIT_HOST%%/*}"      # keep only the hostname (may include user:pass@ if SOURCE_URL embeds credentials)
# Variant with any embedded credentials stripped — used for log lines and the
# persisted remote URL so that PATs never leak into pod logs or .git/config.
# When SOURCE_URL has no credentials, this is identical to GIT_HOST.
GIT_HOST_PUBLIC="${GIT_HOST##*@}"
GIT_PATH="/${SOURCE_URL#*://*/}"
[[ "/${SOURCE_URL}" == "${GIT_PATH}" ]] && GIT_PATH="/"
PROTOCOL="${SOURCE_URL%%://*}"

# Inject token if provided (GitHub / GIT_TOKEN path)
GIT_TOKEN="${GIT_TOKEN:-$GITHUB_TOKEN}"
if [[ -n "$GIT_TOKEN" ]]; then
  SOURCE_URL="${PROTOCOL}://${GIT_TOKEN}@${GIT_HOST_PUBLIC}${GIT_PATH}"
fi

rm -rf "$WORK_DIR"
if [[ -n "$BRANCH" ]]; then
  echo "cloning https://***@${GIT_HOST_PUBLIC}${GIT_PATH} (branch: $BRANCH)"
  git clone --branch "$BRANCH" --depth 1 "$SOURCE_URL" "$WORK_DIR"
else
  echo "cloning https://***@${GIT_HOST_PUBLIC}${GIT_PATH}"
  git clone --depth 1 "$SOURCE_URL" "$WORK_DIR"
fi

# Scrub credentials from origin remote — tokens and embedded credentials must
# not persist to .git/config. This covers both the GIT_TOKEN path and the
# Gitea embedded-credential path (https://user:pass@host/path), and runs
# unconditionally regardless of which path produced the clone URL.
git -C "$WORK_DIR" remote set-url origin "${PROTOCOL}://${GIT_HOST_PUBLIC}${GIT_PATH}"

write_commit_info "$WORK_DIR"

# ---- Sub-path support ----
BUILD_DIR="$WORK_DIR"
if [[ -n "$SUB_PATH" ]]; then
  BUILD_DIR="$WORK_DIR/$SUB_PATH"
fi

# ---- Config service phase ----
if [[ -z "${OSC_ENV:-}" && -n "${OSC_MCP_URL:-}" ]]; then
  _extracted=$(echo "$OSC_MCP_URL" | sed -n 's|.*\.svc\.\([a-z]*\)\.osaas\.io.*|\1|p')
  OSC_ENV=${_extracted:-prod}
fi

# Exchange the runner refresh token for a fresh PAT (if applicable). Uses the
# JSON-body form (matching web-runner), NOT the `Authorization: Bearer` or
# `x-pat-jwt` header forms used by the other 4 runners — those are broken
# against the live token-service endpoint.
if [[ -n "${OSC_ACCESS_TOKEN:-}" && -n "${CONFIG_SVC:-}" ]]; then
  if REFRESH_RESULT=$(curl -sf -X POST \
    "https://token.svc.${OSC_ENV:-prod}.osaas.io/runner-token/refresh" \
    -H "Content-Type: application/json" \
    -d "{\"token\":\"$OSC_ACCESS_TOKEN\"}" 2>/dev/null) && [ -n "$REFRESH_RESULT" ]; then
    FRESH_PAT=$(echo "$REFRESH_RESULT" | jq -r '.token // empty')
    if [ -n "$FRESH_PAT" ]; then
      OSC_ACCESS_TOKEN="$FRESH_PAT"
      echo "[CONFIG] Refreshed access token via runner refresh token"
    fi
  fi
  # If refresh failed, OSC_ACCESS_TOKEN retains its original value (backward compat)
fi

# BEGIN config-load
if [[ -n "$OSC_ACCESS_TOKEN" && -n "$CONFIG_SVC" ]]; then
  echo "[CONFIG] Loading environment variables from config service '$CONFIG_SVC'"
  # NOTE: this script runs under `set -e`. A plain `x=$(cmd)` assignment
  # propagates a non-zero command-substitution exit status and terminates the
  # script immediately, before `config_exit=$?` on the next line is ever read.
  # The same applies to `valid_exports=$(... | grep ...)` when grep matches
  # nothing (exit 1). Every substitution below therefore has an explicit
  # `|| fallback` so the exit handling is actually reached instead of the
  # container dying silently (and the EXIT trap taking /healthz down with it).
  config_max_attempts=3
  config_attempt=1
  config_failed=0
  config_fail_reason=""
  config_exit=0
  config_env_output=""
  config_err_output=""
  valid_exports=""
  config_out_file=$(mktemp)
  config_err_file=$(mktemp)
  while true; do
    config_failed=0
    config_exit=0
    valid_exports=""
    timeout 60s npx -y "@osaas/cli@${OSAAS_CLI_VERSION:?OSAAS_CLI_VERSION is not set}" web config-to-env ${OSC_ENV:+--env "$OSC_ENV"} "$CONFIG_SVC" >"$config_out_file" 2>"$config_err_file" || config_exit=$?
    config_env_output=$(cat "$config_out_file") || config_env_output=""
    config_err_output=$(cat "$config_err_file") || config_err_output=""
    if [ $config_exit -eq 124 ]; then
      config_failed=1
      config_fail_reason="config-to-env timed out after 60s"
    elif [ $config_exit -ne 0 ]; then
      config_failed=1
      config_fail_reason="exit code $config_exit"
    else
      # Only eval lines that are valid shell export statements to prevent
      # executing error messages or malformed output as shell commands
      valid_exports=$(echo "$config_env_output" | grep "^export [A-Za-z_][A-Za-z0-9_]*=") || valid_exports=""
      if [ -z "$valid_exports" ] && [ -n "$config_env_output" ]; then
        config_failed=1
        config_fail_reason="config service returned output with no valid export statements"
      fi
    fi
    if [ $config_failed -eq 0 ]; then
      break
    fi
    # Auth and not-found failures are permanent: do not retry
    if echo "$config_env_output $config_err_output" | grep -qi "expired\|unauthorized\|401\|not found\|404"; then
      break
    fi
    if [ $config_attempt -ge $config_max_attempts ]; then
      break
    fi
    echo "[CONFIG] WARNING: Failed to load config (attempt $config_attempt/$config_max_attempts: $config_fail_reason) - retrying in 3s" >&2
    config_attempt=$((config_attempt + 1))
    sleep 3
  done
  rm -f "$config_out_file" "$config_err_file"

  if [ $config_failed -eq 1 ]; then
    echo "[CONFIG] ERROR: Failed to load config from '$CONFIG_SVC' ($config_fail_reason, exit code $config_exit): $config_env_output $config_err_output" >&2
    if echo "$config_env_output $config_err_output" | grep -qi "expired\|unauthorized\|401"; then
      echo "[CONFIG] Action required: Your OSC_ACCESS_TOKEN may have expired." >&2
      echo "[CONFIG] Use the 'refresh-app-config' MCP tool to issue a fresh token." >&2
    fi
    echo "[CONFIG] Not starting the application without its configuration." >&2
    # Enter the loading server's failed state (/healthz 500 build-failed, / 503)
    # instead of `exit 1`: the EXIT trap would kill the loading server and make
    # /healthz unreachable. Same pattern as the docroot/composer/setup failures.
    kill $LOADING_PID 2>/dev/null || true
    wait $LOADING_PID 2>/dev/null || true
    trap - EXIT
    exec node /runner/loading-server.js error-page.html failed
  fi

  if [ -n "$valid_exports" ]; then
    eval "$valid_exports"
    var_count=$(echo "$valid_exports" | wc -l | tr -d ' ')
    echo "[CONFIG] Loaded $var_count environment variable(s)"
  else
    echo "[CONFIG] Config service '$CONFIG_SVC' has no parameters"
  fi
fi
# END config-load

# ---- Docroot resolution (framework auto-detection) ----
# 1. $OSC_ENTRY (explicit override — resolved relative to BUILD_DIR)
# 2. public/index.php  (Laravel / Symfony / Slim)
# 3. web/index.php     (Drupal / some Symfony)
# 4. index.php at BUILD_DIR root
# 5. otherwise -> error page
DETECTED_DOCROOT=""
if [[ -n "$OSC_ENTRY" ]]; then
  if [[ -f "$BUILD_DIR/$OSC_ENTRY/index.php" ]]; then
    DETECTED_DOCROOT="$BUILD_DIR/$OSC_ENTRY"
  elif [[ -d "$BUILD_DIR/$OSC_ENTRY" ]]; then
    DETECTED_DOCROOT="$BUILD_DIR/$OSC_ENTRY"
  else
    echo "ERROR: OSC_ENTRY '$OSC_ENTRY' is not a directory under $BUILD_DIR" >&2
  fi
elif [[ -f "$BUILD_DIR/public/index.php" ]]; then
  DETECTED_DOCROOT="$BUILD_DIR/public"
elif [[ -f "$BUILD_DIR/web/index.php" ]]; then
  DETECTED_DOCROOT="$BUILD_DIR/web"
elif [[ -f "$BUILD_DIR/index.php" ]]; then
  DETECTED_DOCROOT="$BUILD_DIR"
fi

if [[ -z "$DETECTED_DOCROOT" ]]; then
  echo "ERROR: Could not find an index.php entry point (checked \$OSC_ENTRY, public/, web/, and repo root)" >&2
  kill $LOADING_PID 2>/dev/null || true
  exec node /runner/loading-server.js error-page.html failed
fi

echo "[BUILD] Using docroot: $DETECTED_DOCROOT"

# ---- Dependency install ----
if [[ -f "$BUILD_DIR/composer.json" ]]; then
  echo "[BUILD] Found composer.json, installing dependencies..."
  if ! (cd "$BUILD_DIR" && composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader); then
    echo "Composer install failed" >&2
    kill $LOADING_PID 2>/dev/null || true
    exec node /runner/loading-server.js error-page.html failed
  fi
else
  echo "[BUILD] No composer.json found, skipping dependency install"
fi

# ---- setup.sh escape hatch ----
# Mirrors python-runner's mechanism: an optional setup.sh at the repo root is
# executed (as root) after dependency install, before the app starts.
#
# Bounded with `timeout` so a hung setup.sh cannot block the build forever
# (previously: no timeout, no failure handling — a hang meant `buildStatus`
# stayed `building` indefinitely and `wait-for-app-ready` never got a
# terminal signal). Both a timeout (exit 124) and any other non-zero exit
# are treated as terminal build failures, matching the existing
# docroot-missing and composer-install-failure pattern above.
if [[ -f "$BUILD_DIR/setup.sh" ]]; then
  echo "[BUILD] Running setup.sh..."
  chmod +x "$BUILD_DIR/setup.sh"
  setup_exit=0
  (cd "$BUILD_DIR" && timeout 300s ./setup.sh) || setup_exit=$?
  if [ $setup_exit -eq 124 ]; then
    echo "setup.sh timed out after 300s" >&2
    kill $LOADING_PID 2>/dev/null || true
    exec node /runner/loading-server.js error-page.html failed
  elif [ $setup_exit -ne 0 ]; then
    echo "setup.sh failed (exit $setup_exit)" >&2
    kill $LOADING_PID 2>/dev/null || true
    exec node /runner/loading-server.js error-page.html failed
  fi
fi

# ---- Apache configuration ----
# Apache's default DocumentRoot is /var/www/html; the real docroot is only
# known now (after clone + framework detection), so symlink it in rather than
# rewriting vhost config and reloading.
rm -rf /var/www/html
ln -s "$DETECTED_DOCROOT" /var/www/html

# Apache defaults to Listen 80 / VirtualHost *:80. Rewrite both to the
# runtime PORT so `PORT=9000` moves the app the same way it moves the
# loading server.
sed -i "s/^Listen 80\$/Listen ${PORT}/" /etc/apache2/ports.conf
sed -i "s/<VirtualHost \*:80>/<VirtualHost *:${PORT}>/" /etc/apache2/sites-enabled/000-default.conf

# ---- Run phase ----
kill $LOADING_PID 2>/dev/null || true
wait $LOADING_PID 2>/dev/null || true
trap - EXIT

exec apache2-foreground
