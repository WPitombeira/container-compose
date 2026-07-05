# Container Compose

Container Compose is an open-source macOS tool that brings a Docker Compose-like workflow to Apple's [container](https://github.com/apple/container) runtime.

The project provides:

- `container-compose`: a global command-line tool for loading Compose YAML and planning Apple Container commands.
- `ContainerComposeCore`: a Swift package that can be embedded by [Container Desktop](https://github.com/WPitombeira/container-desktop) and other macOS apps.
- A compatibility-focused Compose loader that preserves unsupported fields with diagnostics instead of silently pretending they work.

Container Compose is released under the MIT License.

## Related Projects

- [WPitombeira/container-compose](https://github.com/WPitombeira/container-compose): this project.
- [WPitombeira/container-desktop](https://github.com/WPitombeira/container-desktop): the macOS GUI that Container Compose is designed to integrate with.
- [apple/container](https://github.com/apple/container): Apple's container runtime and CLI.
- [docker/compose](https://github.com/docker/compose): the Docker Compose CLI reference.
- [Compose Specification](https://compose-spec.github.io/compose-spec/spec.html): the Compose file model reference.

## Requirements

- Apple silicon Mac.
- macOS 26 or newer.
- Apple's `container` CLI installed.
- Apple Container runtime started with:

```sh
container system start
```

## Install

Install the CLI into `$HOME/.local/bin`:

```sh
scripts/install-container-compose.sh
```

Use a custom prefix when needed:

```sh
PREFIX=/usr/local scripts/install-container-compose.sh
```

Uninstall the managed binary:

```sh
scripts/uninstall-container-compose.sh
```

## Quick Start

From a directory containing `compose.yaml`:

```sh
container-compose config
container-compose convert --format yaml
container-compose version
container-compose compatibility
container-compose compatibility --area planner --status preservedDiagnostic
container-compose plan
container-compose up --detach
container-compose port web 80
container-compose logs --follow web
container-compose attach web
container-compose wait web
container-compose scale web=2
container-compose top web
container-compose down
```

Container Compose searches upward from the current directory for `compose.yaml`, `compose.yml`, `docker-compose.yaml`, or `docker-compose.yml`. It also loads the default sibling override file, such as `compose.override.yaml`, when present.

Use ordered files explicitly:

```sh
container-compose plan -f compose.yaml -f compose.override.yaml
```

Read one Compose document from stdin:

```sh
cat compose.yaml | container-compose plan -f -
```

See [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md) for more CLI examples.

## Current Scope

Container Compose currently supports a pragmatic Compose subset for local macOS development:

- Services, images, builds, environment, env files, labels, ports, volumes, networks, configs, secrets, profiles, includes, and service `extends`.
- Docker Compose-style ordered file merging, including `!reset`, `!override`, unique resource merge keys, and duplicate-free sequences.
- Apple Container command planning, model lookups, and diagnostic placeholders for build, pull, push, up, run, create, down, start, stop, restart, kill, pause, unpause, attach, wait, scale, rm, exec, cp, port, logs, ps, top, stats, images, config, convert, compatibility, and doctor workflows.
- Structured diagnostics for Compose fields that are preserved but not yet mapped to Apple Container.
- Versioned JSON plan, execution-report, runtime-status, execution-graph, and tool metadata envelopes for app integrations.

The detailed compatibility strategy is tracked in [docs/COMPOSE_PARITY.md](docs/COMPOSE_PARITY.md).

## Container Desktop

`ContainerComposeCore` is the shared Compose engine intended for [Container Desktop](https://github.com/WPitombeira/container-desktop). Apps should import the Swift package and use `ContainerComposeService` instead of shelling out to the CLI when they need project loading, command previews, dry-run reports, runtime status, or desktop-friendly snapshots.

```swift
import ContainerComposeCore

let service = ContainerComposeService(remoteIncludeResolver: trustedResolver)
let snapshot = try service.makeDesktopSnapshot(.init(
    operation: .up,
    files: ["/path/to/compose.yaml"],
    projectDirectory: "/path/to/project",
    projectName: "my-project",
    detach: true,
    emitReadinessChecks: true
))
```

See [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md) and [docs/CONTAINER_DESKTOP_INTEGRATION.md](docs/CONTAINER_DESKTOP_INTEGRATION.md).

## Documentation

- [docs/README.md](docs/README.md): documentation index.
- [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md): install, first run, and common CLI workflows.
- [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md): integration points for Container Desktop and other tools.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): package structure and planning architecture.
- [docs/ROADMAP.md](docs/ROADMAP.md): prioritized roadmap for the next development phases.
- [docs/COMPOSE_PARITY.md](docs/COMPOSE_PARITY.md): Compose behavior and support tiers.
- [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md): contribution guidelines.
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): local development and verification commands.

## Contributing

Contributors are welcome. The safest way to improve Container Compose is to keep changes focused, add tests for each Compose behavior, and mark unsupported Apple Container behavior with structured diagnostics until it has been verified on the real runtime.

Start with [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md).

## License

Container Compose is open source under the [MIT License](LICENSE).

Third-party references and dependency notices are tracked in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
