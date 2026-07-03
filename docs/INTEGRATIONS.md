# Integrations

Container Compose is built as a package-first Swift project so the CLI and GUI integrations share the same Compose engine.

## Primary Integration: Container Desktop

[Container Desktop](https://github.com/WPitombeira/container-desktop) is the main GUI consumer. It should import `ContainerComposeCore` and use `ContainerComposeService` for:

- Loading and normalizing Compose projects.
- Rendering diagnostics beside services, networks, volumes, configs, secrets, and commands.
- Previewing Apple Container command plans.
- Producing dry-run execution reports.
- Checking runtime availability.
- Enforcing app-owned execution and readiness policies.

Use the detailed guide in [CONTAINER_DESKTOP_INTEGRATION.md](CONTAINER_DESKTOP_INTEGRATION.md) for package wiring and API examples.

## Apple Container Runtime

Container Compose targets Apple's [container](https://github.com/apple/container) CLI. The planner emits command arrays for operations such as:

- `container image pull`
- `container image push`
- `container image list`
- `container build`
- `container network create`
- `container volume create`
- `container run`
- `container create`
- `container start`
- `container stop`
- `container kill`
- `container exec`
- `container copy`
- `container delete`
- `container logs`
- `container list`
- `container stats`

The core library plans commands without requiring SwiftUI or direct process ownership. CLI execution and app execution are intentionally separate.

## Docker Compose Reference

Container Compose is not a Docker daemon adapter. It uses Docker Compose behavior as the compatibility target for the Compose model:

- [docker/compose](https://github.com/docker/compose) is the CLI reference.
- [Compose Specification](https://compose-spec.github.io/compose-spec/spec.html) is the file format reference.
- [compose-go](https://github.com/compose-spec/compose-go) is the practical loader reference for merge, include, extends, interpolation, profile filtering, and validation behavior.

The compatibility strategy is documented in [COMPOSE_PARITY.md](COMPOSE_PARITY.md).

## Public Swift Surface

The stable entry point is `ContainerComposeService`:

```swift
import ContainerComposeCore

let service = ContainerComposeService(remoteIncludeResolver: trustedResolver)
let result = try service.makePlan(.init(
    operation: .up,
    files: ["/path/to/compose.yaml"],
    projectDirectory: "/path/to/project",
    projectName: "my-project",
    profiles: ["debug"],
    composeEnvFiles: ["defaults.env", "local.env"],
    allowRemoteIncludes: false,
    detach: true
))
```

Use:

- `loadProject(_:)` for the normalized Compose model.
- `makePlan(_:)` for command previews.
- `makeDesktopSnapshot(_:)` for UI-ready command rows.
- `dryRun(_:)` and `dryRunDesktopSnapshot(_:)` for planned execution reports without invoking Apple Container.
- `runtimeStatus()` for availability banners and executable discovery.
- `execute(...)` with injected executors when the caller owns process execution.

## Integration Principles

- Treat `ComposeProject` as the source of truth for the active Compose model.
- Treat `AppleContainerPlan.commands` as the source of truth for executable previews.
- Treat diagnostics as structured product data, not log strings.
- Keep remote include fetching app-owned through the injectable resolver.
- Do not re-derive container names in the UI. Use the planner's effective names and readiness metadata.
- Preserve backward-compatible decoding for versioned JSON types whenever adding optional fields.
