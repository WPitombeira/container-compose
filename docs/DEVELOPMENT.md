# Development

This document captures the common local development workflow for Container Compose.

## Package Layout

- `Sources/ContainerComposeCore`: Compose loader, normalized model, compatibility matrix, Apple Container planner, runtime abstractions, and app integration facade.
- `Sources/ContainerComposeCLI`: ArgumentParser executable for the global `container-compose` command.
- `Tests/ContainerComposeCoreTests`: loader, planner, compatibility, runtime, config rendering, and Container Desktop contract tests.
- `Examples`: small Compose files for manual CLI checks.
- `docs`: architecture, parity, integration, and contribution guides.

## Build

```sh
swift build
swift build --product container-compose
```

## Test

```sh
swift test
```

For focused test work:

```sh
swift test --filter ComposeLoaderTests
swift test --filter AppleContainerPlannerTests
swift test --filter ContainerDesktopIntegrationContractTests
```

## Manual CLI Checks

```sh
swift run container-compose config -f Examples/compose.yaml
swift run container-compose config --format yaml -f Examples/compose.yaml
swift run container-compose compatibility
swift run container-compose plan -f Examples/compose.yaml
swift run container-compose up --detach -f Examples/compose.yaml --dry-run
```

## Runtime Checks

Before executing real containers:

```sh
container system start
```

Then run a small example:

```sh
swift run container-compose up --detach -f Examples/compose.yaml
swift run container-compose ps -f Examples/compose.yaml
swift run container-compose logs -f Examples/compose.yaml
swift run container-compose down -f Examples/compose.yaml
```

Only claim runtime support after testing the actual Apple Container command path.

## Container Desktop Smoke Checks

When a local Container Desktop checkout is available, add Container Compose as a SwiftPM dependency and verify that the app can:

- Import `ContainerComposeCore`.
- Create a desktop snapshot.
- Render command previews and diagnostics.
- Use injected execution without shelling out to `container-compose`.

The public integration contract is documented in [CONTAINER_DESKTOP_INTEGRATION.md](CONTAINER_DESKTOP_INTEGRATION.md).

## Release Hygiene

Before publishing a change:

```sh
swift test
git diff --check
```

Also verify:

- README and docs match the implemented support level.
- `LICENSE` is present.
- Public `Codable` additions have default decoding where possible.
- Diagnostics remain structured and path-specific.
