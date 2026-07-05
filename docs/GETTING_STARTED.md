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

Check the installed tool and schema metadata:

```sh
container-compose version
container-compose version --format json
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
container-compose convert --format yaml
container-compose config --format yaml
container-compose config --environment
container-compose config --variables
container-compose config --hash '*'
container-compose config --no-interpolate
container-compose config --no-env-resolution
container-compose config --services
container-compose config --images
container-compose config --models
container-compose version
container-compose version --format json
container-compose compatibility --format json
container-compose compatibility --area planner --status preservedDiagnostic
container-compose ls --all --format json
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
container-compose pause web
container-compose unpause web
container-compose attach web
container-compose wait --down-project web
container-compose scale --no-deps web=2
container-compose commit --message snapshot web example/web:snapshot
container-compose export -o web.tar web
container-compose events --json --since 1h web
container-compose watch --no-up web
container-compose volumes --format json web
container-compose publish --app example/app:latest
container-compose rm --stop web
container-compose exec web sh
container-compose cp web:/var/log/app.log ./app.log
container-compose port web 80
container-compose logs --follow web
container-compose ps web
container-compose top web
container-compose stats --no-stream web
container-compose down --volumes
```

## Plans and Diagnostics

`container-compose version --format json` emits the tool version plus the current plan, execution-report, execution-graph, and runtime-status schema versions.

`container-compose convert` is a Docker Compose-compatible alias for rendering the normalized model. It shares the same projection flags as `config`, including `--services`, `--images`, `--profiles`, `--networks`, `--volumes`, `--models`, `--environment`, `--variables`, `--hash SERVICE|*`, `--no-interpolate`, `--no-env-resolution`, `--format`, `--output`, and `--quiet`.

`container-compose plan` emits a versioned JSON envelope containing:

- Project metadata.
- Runtime target.
- Selected service targets.
- Structured diagnostics.
- Planned Apple Container command arrays.
- Optional execution graph and readiness metadata.

Diagnostics are part of the product. Container Compose should warn when Compose behavior is preserved but not yet mapped to Apple Container, and error when a Compose file is contradictory or invalid.

`container-compose port SERVICE PRIVATE_PORT` resolves the declared Compose published port from the normalized model. It supports `--protocol` and `--index`, but `--index` emits a diagnostic because static Compose resolution does not inspect per-replica runtime state.

`container-compose pause` and `container-compose unpause` accept Docker Compose's service-targeting shape and emit planned actions with diagnostics. Execution is blocked before invoking Apple Container until pause and unpause support is verified.

`container-compose attach SERVICE` accepts Docker Compose's single-service attach shape and preserves attach options in the plan. Execution is blocked before invoking Apple Container until interactive stream, detach-key, and signal-proxy behavior is verified.

`container-compose wait [SERVICE...]` preserves Docker Compose's stop-wait intent, including `--down-project`. It is separate from `up --wait`, which models dependency readiness before starting services.

`container-compose scale SERVICE=REPLICAS...` preserves Docker Compose's imperative replica-count intent, including `--no-deps`. Execution is blocked before invoking Apple Container until replica orchestration is verified.

`container-compose commit [OPTIONS] SERVICE [REPOSITORY[:TAG]]` preserves Docker Compose's image-snapshot intent, including author, change, message, index, and pause options. Execution is blocked before invoking Apple Container until image commit behavior is verified.

`container-compose export [OPTIONS] SERVICE` preserves Docker Compose's service-filesystem archive intent, including `--index` and `-o/--output`. Execution is blocked before invoking Apple Container until filesystem tar export behavior is verified.

`container-compose events [OPTIONS] [SERVICE...]` preserves Docker Compose's project event-stream intent, including `--json`, `--since`, and `--until`. The `--json` flag belongs to the event stream format and does not request a Container Compose execution-report JSON envelope for this command.

`container-compose watch [SERVICE...]` preserves Docker Compose's file-watch intent, including `--no-up`, `--prune`, `--quiet`, service filters, and any `develop.watch` rules in the active model. Execution is blocked before invoking Apple Container until file sync, rebuild, restart, and `sync+exec` behavior is verified.

`container-compose publish [OPTIONS] REPOSITORY[:TAG]` preserves Docker Compose's OCI application publication intent, including `--app`, `--oci-version`, `--resolve-image-digests`, `--with-env`, and `-y/--yes`. Execution is blocked before invoking Apple Container until registry packaging, image digest resolution, and environment inclusion behavior are verified.

`container-compose ls [OPTIONS]` preserves Docker Compose's runtime project-list intent and does not require a Compose file in the current directory. It accepts `--all`, repeated `--filter`, `--format table|json`, and `--quiet`, but remains diagnostic-only until Apple Container project metadata discovery is verified.

`container-compose volumes [OPTIONS] [SERVICE...]` preserves Docker Compose's project volume-list intent, including `--format`, `--quiet`, and service filters. Execution is blocked before invoking Apple Container until project-scoped and service-scoped volume discovery is verified.

`container-compose top` maps Docker Compose's process view to `container exec SERVICE ps` for each selected service and emits a diagnostic because Apple Container does not expose Docker's host-side process table.
