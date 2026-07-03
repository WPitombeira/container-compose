# Compose Parity Notes

Container Compose targets a Docker Compose-like workflow for Apple's `container` runtime, but it is not a Docker daemon adapter. This document records the reference behavior we intentionally mirror and the places where Apple Container support must remain diagnostic-only until verified.

## Primary References

- [Docker Compose](https://github.com/docker/compose) is the user-facing CLI reference. Its README frames Compose as a tool for running applications defined by the Compose file format with `docker compose up`.
- [Compose Specification](https://compose-spec.github.io/compose-spec/spec.html) is the model reference. It defines services as the compute units plus networks, volumes, configs, secrets, profiles, includes, interpolation, and platform-specific optional attributes.
- [compose-go](https://github.com/compose-spec/compose-go) is the loader reference used by Docker Compose and other tools. Its loader options and flow establish the practical order for file loading, interpolation, include, extends, merge, validation, canonicalization, profile selection, resource pruning, and environment/label file resolution.

## Loader Pipeline Target

Container Compose should keep matching this high-level compose-go pipeline:

1. Discover or accept ordered Compose sources.
2. Establish project name, working directory, process environment, and `.env` / explicit env-file defaults.
3. Parse YAML into a raw model while preserving Compose tags such as `!reset` and `!override`.
4. Interpolate values before converting into typed models.
5. Apply `include` before `extends` so extended services can depend on included definitions.
6. Resolve `extends` with cycle detection and path rebasing for file-defined base services.
7. Merge ordered files with Compose override semantics, including unique-resource keys for ports, volumes, configs, and secrets.
8. Validate known contradictions early, for example `network_mode` together with service `networks`.
9. Canonicalize short and long syntax into the public Swift model.
10. Apply profile and selected-service filtering while preserving dependency metadata.
11. Resolve env-file and label-file side effects only for active services.
12. Emit a normalized model plus structured diagnostics instead of hiding unsupported fields.

This sequence matters for `container-desktop`: the app should be able to preview the same active project that CLI execution would use, including diagnostics, graph edges, generated files, and remote include provenance.

## Compatibility Tiers

Container Compose should classify every known Compose field into one of these tiers:

- `Mapped`: the field has a verified Apple Container command equivalent and is planned as concrete `container` arguments.
- `Preserved diagnostic`: the field is parsed into the public model, survives `config` output, and emits planner diagnostics because Apple Container behavior is unavailable, platform-specific, or unverified.
- `Rejected diagnostic`: the field is known, but the Compose value is invalid or contradictory, so the loader emits an error diagnostic and avoids unsafe planning.
- `Unknown`: the field is not implemented yet; the loader warns rather than silently pretending it works.

New work should prefer `Preserved diagnostic` before `Mapped` unless the Apple Container CLI behavior has been verified on the real runtime path. This keeps Container Desktop honest: UI previews can show users what was understood and what will not be applied.

## Public Model Rules

- Public `Codable` structs must decode older JSON by defaulting newly added arrays, dictionaries, and booleans where possible.
- New fields should use Compose names in diagnostics and Swift names in the normalized model.
- Opaque raw YAML should be avoided when a small typed model is practical. Typed preservation makes Container Desktop forms, diff views, and warning placement easier.
- Diagnostics should point to the Compose path, for example `services.web.blkio_config.device_read_bps[0].rate`.
- Planner diagnostics should be emitted at the command that would have consumed the setting.

## Apple Container Mapping Rules

- Do not infer Docker flags from similar-looking Apple Container flags without runtime verification.
- Do not map Linux-kernel-specific Compose attributes by default. Keep them diagnostic-only unless Apple Container documents and demonstrates equivalent behavior.
- Prefer static, previewable plans. Dynamic Docker Compose behavior such as conditional pull-then-build fallback should stay diagnostic-only until represented in the plan/execution model.
- Container IDs in plans must come from the planner's effective name logic, not from UI-side re-derivation.

## Container Desktop Contract

Container Desktop should treat `ContainerComposeCore` as the Compose engine:

- Use `ContainerComposeService` for loading, planning, dry-run reports, runtime status, and desktop snapshots.
- Use `ComposeCompatibilityMatrix.current` or `container-compose compatibility --format json` when the UI needs a support matrix for mapped, preserved diagnostic, rejected diagnostic, and unsupported Compose fields. The CLI can filter by support tier with `--status` and by implementation surface with `--area loader|planner|runtime|integration`.
- Render `ComposeProject` as the source of truth for the active model.
- Render `AppleContainerPlan.commands` as the source of truth for executable previews.
- Render `AppleContainerPlan.executionGraph` for service ordering and readiness requirements.
- Render diagnostics beside the relevant service, resource, or command rather than flattening them into generic errors.
- Keep remote include network access app-owned through the injectable resolver boundary.

## Near-Term Parity Backlog

- Preserve remaining Linux namespace and process-control fields not already represented.
- Expand the compatibility matrix into a generated audit that cross-checks README support claims, model fields, loader support, planner diagnostics, and tests.
- Add direct repository-level Container Desktop smoke coverage once the local checkout path is stable.
