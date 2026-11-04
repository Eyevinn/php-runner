FROM composer:2 AS composer-stage

FROM php:8.3.36-apache

# System packages:
# - bash, git, curl, jq: entrypoint scripting + commit metadata
# - unzip: required by Composer for zip-distributed packages
# - gnupg: needed by the NodeSource setup script (gpg --dearmor)
# - libbrotli1: upgraded to the trixie-security build (CVE-2026-111497, also used by libcurl)
RUN apt-get update \
  && apt-get install -y --no-install-recommends bash git curl jq unzip gnupg libbrotli1 \
  && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' libbrotli1)" ge 1.1.0-2+deb13u1 \
    || { echo "libbrotli1 below 1.1.0-2+deb13u1 (CVE-2026-111497)"; exit 1; } \
  && rm -rf /var/lib/apt/lists/*

# Node.js 24 from NodeSource (npm/npx included): runs the loading server and
# `npx @osaas/cli web config-to-env`. Pinned to the 24.x line (not setup_lts.x);
# the build fails below the fixed release 24.22.1 (CVE-2026-111497).
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
  && apt-get install -y nodejs \
  && node -e 'const [M,m,p]=process.versions.node.split(".").map(Number); if (M!==24||m<22||(m===22&&p<1)) { console.error("Node "+process.versions.node+" is below 24.22.1 (CVE-2026-111497)"); process.exit(1) }' \
  && node --version \
  && npx --version \
  && rm -rf /var/lib/apt/lists/*

# Composer, copied from the official Composer image (multi-stage, not installed via curl|php).
COPY --from=composer-stage /usr/bin/composer /usr/bin/composer

# Enable mod_rewrite and allow .htaccess overrides for the docroot.
# Debian's php:8.3-apache ships `AllowOverride None` for /var/www/ in
# apache2.conf, which makes .htaccess/mod_rewrite inert even after
# `a2enmod rewrite`. This conf-available snippet is loaded via
# IncludeOptional conf-enabled/*.conf, which apache2.conf includes AFTER its
# own <Directory /var/www/> block, so this override wins.
RUN a2enmod rewrite \
  && { \
    echo '<Directory /var/www/>'; \
    echo '    AllowOverride All'; \
    echo '</Directory>'; \
  } > /etc/apache2/conf-available/osc-allow-override.conf \
  && a2enconf osc-allow-override

# PHP error handling. The base image activates no php.ini, so PHP's compiled-in
# defaults apply (display_errors=1, log_errors=0): startup warnings such as an
# oversized POST body are printed into the response before any app code runs and
# break the app's own header() calls. A conf.d drop-in sets only the two keys we
# need; copying php.ini-production would also change variables_order (empties
# $_ENV), short_open_tag, output_buffering and zend.assertions. log_errors is
# paired on purpose: with display off, errors would otherwise leave no trace.
# error_log stays unset so errors go to Apache's ErrorLog (container stderr).
# The "zz-" prefix keeps this file last, conf.d is parsed alphabetically.
RUN { \
    echo 'display_errors = Off'; \
    echo 'log_errors = On'; \
  } > "$PHP_INI_DIR/conf.d/zz-osc-errors.ini" \
  && php --ini | grep -q 'zz-osc-errors.ini' \
  && php -r 'exit(filter_var(ini_get("display_errors"), FILTER_VALIDATE_BOOLEAN) ? 1 : 0);' \
  && php -r 'exit(filter_var(ini_get("log_errors"), FILTER_VALIDATE_BOOLEAN) ? 0 : 1);'

COPY scripts/loading-server.js scripts/loading-page.html scripts/error-page.html /runner/
WORKDIR /runner
COPY scripts/docker-entrypoint.sh ./
RUN chmod +x /runner/docker-entrypoint.sh

VOLUME /usercontent
# Version of @osaas/cli that docker-entrypoint.sh runs via npx. This is the
# single place the version is pinned; bump it here.
ENV OSAAS_CLI_VERSION=4.35.0
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/runner/docker-entrypoint.sh"]
