# Getting Started

Container Compose loads Compose YAML and produces Apple Container commands. It can be used as a global CLI or imported as `ContainerComposeCore` by a macOS app.

## Requirements

- Apple silicon Mac.
- macOS 26 or newer.
- Apple's [container](https://github.com/apple/container) CLI installed.
- Runtime started before executing real containers:

```sh
container system start
```

You can still run `config`, `compatibility`, `plan`, and dry-run style workflows without executing Apple Container commands.

## Install the CLI

From the repository root:

```sh
scripts/install-container-compose.sh
```

The installer defaults to `$HOME/.local/bin`. To install somewhere else:

```sh
PREFIX=/usr/local scripts/install-container-compose.sh
```

The installer refuses system-protected directories and requires `FORCE=1` before replacing a different existing binary.

Uninstall:

```sh
scripts/uninstall-container-compose.sh
```

## First Run

Given a `compose.yaml`:

```yaml
services:
  web:
    image: nginx:latest
    ports:
      - "8080:80"
```

Inspect the normalized model:

```sh
container-compose config
```

See support status:

```sh
container-compose compatibility
```

Preview Apple Container commands:

```sh
container-compose plan
```

Run the service:

```sh
container-compose up --detach
```

Stop and remove project containers:

```sh
container-compose down
```

## Compose File Discovery

When no `--file` flag is provided, Container Compose searches the current directory and then parent directories for:

- `compose.yaml`
- `compose.yml`
- `docker-compose.yaml`
- `docker-compose.yml`

When the first Compose file is found, Container Compose also loads a sibling default override file such as `compose.override.yaml` when present.

Use explicit ordered files:

```sh
container-compose plan -f compose.yaml -f compose.override.yaml
```

Later files override earlier files using Compose merge rules.

## Stdin and In-Memory Compose

Use `-f -` to read one Compose document from stdin:

```sh
cat compose.yaml | container-compose plan -f -
```

Stdin can be combined with file-backed sources:

```sh
cat compose.override.yaml | container-compose config -f compose.yaml -f - --services
```

Relative paths in stdin input resolve from `--project-directory`, which defaults to the current directory.

## Environment Files

Use `--env-file` to provide interpolation defaults instead of the implicit `.env` next to the Compose file:

```sh
container-compose config --env-file defaults.env --env-file local.env
```

Later env files override earlier env files. Process environment variables still take precedence.

## Common Commands

```sh
container-compose config
container-compose config --format yaml
container-compose config --services
container-compose config --images
container-compose compatibility --format json
container-compose plan
container-compose up --detach web
container-compose run --rm web sh
container-compose create web
container-compose build web
container-compose pull web
container-compose push web
container-compose images --format json
container-compose start web
container-compose stop web
container-compose restart web
container-compose kill --signal SIGINT web
container-compose rm --stop web
container-compose exec web sh
container-compose cp web:/var/log/app.log ./app.log
container-compose logs --follow web
container-compose ps web
container-compose stats --no-stream web
container-compose down --volumes
```

## Plans and Diagnostics

`container-compose plan` emits a versioned JSON envelope containing:

- Project metadata.
- Runtime target.
- Selected service targets.
- Structured diagnostics.
- Planned Apple Container command arrays.
- Optional execution graph and readiness metadata.

Diagnostics are part of the product. Container Compose should warn when Compose behavior is preserved but not yet mapped to Apple Container, and error when a Compose file is contradictory or invalid.
