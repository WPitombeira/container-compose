# Contributing

Contributions are welcome. Container Compose is open source under the MIT License and aims to be useful to the wider Apple Container and macOS developer community.

## How to Help

Good contributions include:

- Compose compatibility improvements.
- Apple Container mapping verified against the real runtime.
- Container Desktop integration improvements.
- Clear diagnostics for unsupported or partially supported Compose behavior.
- Documentation and examples.
- Focused tests that capture Compose edge cases.

## Before You Start

Please read:

- [GETTING_STARTED.md](GETTING_STARTED.md)
- [ARCHITECTURE.md](ARCHITECTURE.md)
- [COMPOSE_PARITY.md](COMPOSE_PARITY.md)
- [INTEGRATIONS.md](INTEGRATIONS.md)

For behavior parity, prefer the Compose Specification and Docker Compose behavior over intuition. For Apple Container mapping, prefer verified runtime behavior over similar-looking flags.

## Development Setup

Clone the repository:

```sh
git clone https://github.com/WPitombeira/container-compose.git
cd container-compose
```

Run tests:

```sh
swift test
```

Build the CLI:

```sh
swift build --product container-compose
```

Run a local command:

```sh
swift run container-compose config -f Examples/compose.yaml
```

More development commands are listed in [DEVELOPMENT.md](DEVELOPMENT.md).

## Contribution Guidelines

- Keep pull requests focused on one behavior or integration concern.
- Add or update tests for every loader, planner, or public API change.
- Preserve backward-compatible decoding for public `Codable` models.
- Use structured diagnostics for unsupported Compose behavior.
- Do not map a Compose field to Apple Container until the runtime behavior has been verified.
- Keep `ContainerComposeCore` independent from SwiftUI and direct UI concerns.
- Keep CLI behavior and Container Desktop APIs aligned through shared core types.
- Prefer typed preservation over raw unstructured YAML when adding Compose fields.
- Update docs when support status, public APIs, or user workflows change.

## License Hygiene

Container Compose is MIT-licensed. Docker Compose, compose-go, and some Apple Swift package dependencies are Apache-2.0 licensed, so treat them carefully:

- Use Docker Compose and compose-go as behavioral references unless maintainers explicitly approve importing source.
- Do not copy, translate, vendor, or modify Apache-2.0 source code without preserving required copyright, license, attribution, and NOTICE material.
- If Apache-2.0 code is imported, update [../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md), include the relevant Apache-2.0 license text and NOTICE attribution, and mark modified copied files as changed from the upstream source.
- Record source provenance in the pull request when behavior is derived from Docker Compose tests, code, or documentation.

## Compose Compatibility Work

When adding a Compose field:

1. Add a typed model when the field should survive `config` output or app inspection.
2. Parse short and long syntax when Compose supports both.
3. Add merge behavior if the field participates in ordered file merge or `extends`.
4. Add loader diagnostics for invalid or contradictory values.
5. Add planner diagnostics when Apple Container cannot map the field yet.
6. Add tests for parsing, merging, diagnostics, and public JSON decoding when applicable.
7. Update [COMPOSE_PARITY.md](COMPOSE_PARITY.md) if the support tier changes.

## Pull Request Checklist

- Tests pass locally.
- New behavior has focused test coverage.
- Documentation is updated when user-facing behavior changes.
- Diagnostics include useful Compose paths.
- Public model additions decode older JSON safely.
- The change does not claim Apple Container support that has not been verified.

## Reporting Issues

When reporting a bug, include:

- macOS version.
- Apple Container version or `container --version` output.
- The Compose YAML or a minimal reproduction.
- The Container Compose command you ran.
- The diagnostics or plan output.
- Whether the issue affects the CLI, Container Desktop integration, or both.

Please avoid sharing secrets from env files, registry credentials, private image names, or production paths.
