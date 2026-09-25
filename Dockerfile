ARG PHP_IMAGE=php:8.3-apache

FROM node:20-alpine AS loading-stage
WORKDIR /loading
COPY scripts/loading-server.js scripts/loading-page.html scripts/error-page.html ./

FROM composer:2 AS composer-stage

FROM ${PHP_IMAGE}

# System packages:
# - bash, git, curl, jq: entrypoint scripting + commit metadata
# - unzip: required by Composer for zip-distributed packages
# - nodejs, npm: runs the loading server and `npx @osaas/cli web config-to-env`
RUN apt-get update \
  && apt-get install -y --no-install-recommends bash git curl jq unzip nodejs npm \
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

COPY --from=loading-stage /loading /runner/
WORKDIR /runner
COPY scripts/docker-entrypoint.sh ./
RUN chmod +x /runner/docker-entrypoint.sh

VOLUME /usercontent
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/runner/docker-entrypoint.sh"]
