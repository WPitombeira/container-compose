# Roadmap

Container Compose is early-stage infrastructure for a Docker Compose-like workflow on top of Apple's `container` runtime. The roadmap is organized around verifiable behavior rather than broad claims of Compose compatibility.

## Current Baseline

- SwiftPM package with `ContainerComposeCore` and the `container-compose` executable.
- Compose YAML discovery, interpolation, ordered file merge, `include`, `extends`, profiles, and normalized config output.
- Apple Container planning, model lookups, and diagnostic placeholders for the core local-development lifecycle: build, pull, push, publish, up, run, create, down, start, stop, restart, kill, pause, unpause, attach, wait, scale, commit, export, events, watch, ls, volumes, rm, exec, cp, port, logs, ps, top, stats, images, config, convert, compatibility, and doctor.
- Public integration surface for Container Desktop through `ContainerComposeService`, desktop snapshots, execution reports, runtime status, and injected executors.
- MIT-licensed open-source repository with contributor and development docs.

## Priority 1: Keep Container Desktop Integration Stable

- Maintain `ContainerComposeCore` as a SwiftUI-free package dependency.
- Keep `ContainerComposeService` as the app-facing facade for load, plan, dry-run, runtime status, and execution.
- Preserve backward-compatible decoding for public JSON envelopes and desktop snapshot types.
- Add repository-level smoke coverage against `WPitombeira/container-desktop` when a stable local checkout or CI fixture is available.
- Treat command arrays, generated files, readiness requirements, and structured diagnostics as the app contract.

## Priority 2: Make Compose Parity Auditable

- Expand `ComposeCompatibilityMatrix.current` into the source of truth for support status.
- Add an audit that cross-checks support claims across docs, model fields, loader parsing, planner diagnostics, and tests.
- Continue implementing Compose behavior in small slices: parse, merge, validate, preserve, diagnose, then map to Apple Container only after runtime verification.
- Keep `compose-go` and the Compose Specification as the reference for loader order, include, extends, interpolation, merge rules, profile filtering, and validation behavior.

## Priority 3: Verify Apple Container Mappings

- Build a lightweight runtime-verification checklist for each mapped Apple Container flag.
- Keep Linux-specific, security, namespace, device, and orchestration fields diagnostic-only until Apple Container documents or demonstrates equivalent behavior.
- Prefer static, previewable plans over dynamic behavior that cannot be represented safely in the current execution model.
- Record verified runtime behavior in tests or docs so future changes do not rely on memory.

## Priority 4: Improve Developer and Contributor Flow

- Keep README focused on project identity, install, quick start, docs, and contributing.
- Keep detailed workflows in separate docs under `docs/`.
- Add issue templates once the repository starts receiving external feedback.
- Add CI for `swift test`, `git diff --check`, and documentation link checks.
- Consider release artifacts for signed or notarized macOS CLI distribution after the API stabilizes.

## Not Yet Goals

- Claiming full Docker Compose compatibility.
- Acting as a Docker daemon adapter.
- Hiding unsupported Compose fields.
- Mapping Apple Container flags based only on similar Docker flag names.
- Baking network fetching policy into the core library instead of leaving it app-owned.
