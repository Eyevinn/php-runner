# php-runner

A container runtime that enables deploying PHP applications as My Apps on [Eyevinn Open Source Cloud](https://www.osaas.io/).

## What it does

php-runner clones your PHP repository, installs dependencies with Composer, and serves the app with Apache + mod_php (`php:8.3-apache`). It integrates with the OSC platform for config service support, build status signaling, and token-based authentication.

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `SOURCE_URL` | Yes (or `GITHUB_URL`) | HTTPS URL of the Git repository to clone. Append `#branchname` to specify a branch. |
| `GITHUB_URL` | Yes (or `SOURCE_URL`) | Alias for `SOURCE_URL` (backward compatibility). |
| `GIT_TOKEN` | No | Personal access token for private repositories. Injected into the clone URL. |
| `GITHUB_TOKEN` | No | Fallback for `GIT_TOKEN`. |
| `SUB_PATH` | No | Subdirectory within the cloned repo to use as the app root (monorepo support). |
| `OSC_ENTRY` | No | Override the auto-detected docroot. Must resolve to a directory (relative to the app root) containing `index.php`. |
| `PORT` | No | Port Apache (and the loading server) listen on. Default: `8080`. |
| `OSC_ACCESS_TOKEN` | No | OSC runner token for authenticating with the config service. |
| `CONFIG_SVC` | No | OSC config service endpoint for loading environment variables at startup. |

Note: there is no separate `CONFIG_API_KEY` variable to set. Decryption of encrypted parameter-store values happens inside `npx @osaas/cli web config-to-env`, which reads the necessary credentials from the ambient environment (populated via the config service integration) rather than from an explicit variable read in this entrypoint.

## PHP Framework Auto-Detection

When `OSC_ENTRY` is not set, the entrypoint detects your app's document root in this order:

1. `public/index.php` — Laravel, Symfony, Slim
2. `web/index.php` — Drupal, some Symfony setups
3. `index.php` at the repo root
4. Otherwise the container fails to start and serves the error page

The detected directory is symlinked to Apache's `DocumentRoot` (`/var/www/html`) at container start, since the real docroot is only known after the repo is cloned.

## Composer

If a `composer.json` is found at the app root, dependencies are installed with:

```
composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader
```

## `setup.sh` Escape Hatch

If a `setup.sh` script exists at the app root, it is made executable and run (as root) after `composer install` and before Apache starts. Use this for any one-off setup step your app needs (e.g. running database migrations, generating framework caches) that isn't covered by `composer install` alone.

## `.htaccess` / `mod_rewrite`

Unlike Debian's default `php:8.3-apache` image, this runner explicitly sets `AllowOverride All` for the document root and enables `mod_rewrite` at build time, so `.htaccess`-based routing (used by most PHP frameworks) works out of the box.

## Example Usage

### Deploy a public PHP app

```
SOURCE_URL=https://github.com/your-org/your-php-app
```

### Deploy from a private repository

```
SOURCE_URL=https://github.com/your-org/private-php-app
GIT_TOKEN=ghp_yourtokenhere
```

### Deploy from a specific branch

```
SOURCE_URL=https://github.com/your-org/your-php-app#feat/new-api
```

### Monorepo with a subdirectory

```
SOURCE_URL=https://github.com/your-org/monorepo
SUB_PATH=services/my-php-app
```

### Override the docroot explicitly

```
SOURCE_URL=https://github.com/your-org/your-php-app
OSC_ENTRY=public
```

## Build Status Signaling

While the repo is being cloned and dependencies installed, a loading server runs on `PORT` and responds to health checks:

- `GET /healthz` returns `503 Building` while the build is in progress
- `GET /healthz` returns `500 {"status":"build-failed"}` if the build fails
- All other requests return the loading page HTML

Once the app is ready, the loading server is stopped and Apache takes over — `/healthz` (and every other path) is then served by your application, if it defines a route for it.

## OSC Config Service

If both `OSC_ACCESS_TOKEN` and `CONFIG_SVC` are set, the runner loads environment variables from the OSC config service before installing dependencies. This allows secrets and runtime configuration to be managed through the OSC platform rather than being passed as container environment variables.

## Docker Image

The image is built on `php:8.3-apache` (Debian, Apache 2 + mod_php) and includes:
- `bash`, `git`, `curl`, `jq`, `unzip`, `nodejs`, `npm`
- Composer 2, copied from the official `composer:2` image
- `mod_rewrite` enabled and `AllowOverride All` for the document root

PHP version is pinned to 8.3 for this runner; there is no multi-version support.
