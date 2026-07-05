# Architecture

Container Compose follows the same package-first SwiftPM approach as `container-desktop`: macOS 26 floor, Swift code, and a narrow boundary around Apple's `container` CLI.

## Layers

1. `ContainerComposeCLI`
   - ArgumentParser executable.
   - Owns user-facing commands: `config`, `plan`, `up`, `run`, `create`, `build`, `down`, `start`, `pull`, `push`, `images`, `stop`, `restart`, `kill`, `pause`, `unpause`, `attach`, `wait`, `scale`, `rm`, `exec`, `cp`, `logs`, `ps`, `top`, and `stats`.
   - Executes `container` only after showing or building a command plan.
   - Ships as a SwiftPM executable that can be installed to a user-selected `PREFIX/bin`.

2. `ContainerComposeCore`
   - Loads Compose YAML from disk.
   - Normalizes supported Compose syntax into Swift models.
   - Emits diagnostics for unsupported or partially supported fields.
   - Plans Apple Container commands without executing them.
   - Exposes `ContainerComposeService` as the public app-facing facade for project loading, operation planning, dry-run reports, and injected execution.
   - Exposes `ContainerComposeMetadata.currentVersionInfo` so CLI users and Container Desktop can inspect tool and schema versions through one public contract.
   - Exposes a versioned `AppleContainerPlan` envelope for CLI JSON output and `container-desktop` integration.
   - Exposes a versioned `AppleContainerExecutionReport` envelope for machine-readable runtime results.

3. Apple Container runtime
   - Invoked as `container <arguments>`.
   - Current plan target uses `container image pull`, `container image push`, `container image list`, `container build`, `container network create`, `container volume create`, `container run`, `container create`, `container start`, `container stop`, `container kill`, `container exec`, `container copy`, `container delete`, `container logs`, `container list`, and `container stats`. Pause, unpause, attach, wait, and scale are diagnostic-only until Apple Container behavior is verified.

## Compose Compatibility Strategy

Docker Compose uses the Compose Specification as an application model: services are the core compute units, with networks, volumes, configs, secrets, profiles, interpolation, include, and merge forming the full model. Container Compose should not claim full parity early. It should load the common local-development subset first and make gaps explicit.

The detailed parity rules, compose-go loader sequence, support tiers, and Container Desktop invariants are tracked in [COMPOSE_PARITY.md](COMPOSE_PARITY.md).

MVP behavior:

- Prefer canonical `compose.yaml`, then fallback names, walking from the working directory up through parent directories when no explicit file list is provided.
- Support ordered multi-file merge from repeated `--file` values and default sibling override files.
- Support Docker Compose-style `--file -` / `-f -` for one stdin Compose document by translating CLI stdin into the same ordered in-memory YAML source path used by `ContainerDesktop` snippets. Stdin can participate in ordered multi-file merges, and relative paths are anchored to `--project-directory`, matching the current working directory default.
- Use Compose-style environment defaults for `COMPOSE_FILE`, `COMPOSE_PROFILES`, and `COMPOSE_PROJECT_NAME`, with explicit CLI flags taking precedence. Support repeatable global `--env-file` / `ContainerComposePlanRequest.composeEnvFiles` for interpolation defaults that replace the implicit `.env` file while still yielding to process environment values.
- Apply Compose profile filtering while allowing explicitly targeted services to activate their own profiles. Dependencies hidden behind unrelated inactive profiles remain inactive and produce diagnostics when referenced.
- Load `.env` from the Compose file directory and apply Compose-style interpolation to parsed YAML values, including `$VAR`, `${VAR}`, defaults, required variables, alternates, nested expressions, and `$$` escapes. Mapping keys are preserved, matching Compose's key-interpolation rules.
- Expose Docker Compose `config` output controls for the normalized active model. `--format json|yaml` renders the resolved model, `-o/--output` writes it to disk, `--services`, `--images`, `--profiles`, `--networks`, and `--volumes` print deterministic one-value-per-line lists, and `--quiet` validates without output. Expose Docker Compose `convert` as the same normalized-model renderer with a distinct operation name for CLI parity and app telemetry.
- Resolve `include` entries after the selected file stack is merged, recursively copy included services, networks, volumes, configs, and secrets, support local include-specific `env_file` defaults, and warn when included resource names conflict with the current project.
- Support opt-in `http` and `https` remote includes through injectable fetcher and resolver hooks. The resolver receives sanitized URL and include-lineage context so `container-desktop` can enforce network consent, host allowlists, and cache policy; returned cache metadata is exposed on `ComposeProject.remoteIncludes`. Remote include `env_file` values are warned and ignored until a safe cross-origin env policy exists.
- Resolve service `extends` before service parsing. The child service merges the referenced service first, then applies its own mapping/scalar overrides and sequence additions through the same raw merge helpers used for ordered file overlays. Duplicate-free Compose sequences such as capabilities, exposed ports, external links, device cgroup rules, and security options are deduplicated, while ports, volumes, configs, and secrets use their Compose unique-resource keys. File-based `extends` loads explicit target files directly, tracks cycles by source path plus service, and rewrites relative `env_file`, build context/additional context, and bind-volume paths from the external file into the current Compose file's coordinate space. The loader emits Compose's special healthcheck merge rejection when an extending service newly disables healthchecks.
- Preserve service `env_file` long syntax metadata, including `path`, `required`, and `format`, while retaining the existing path list projection for app consumers. Optional missing env files are skipped in Apple Container run plans; non-default formats remain diagnostic-only until Apple Container env-file parsing can model them directly.
- Treat Compose `x-*` extension fields as user-defined metadata and do not report them as unsupported fields at the top level or inside known nested maps.
- Resolve simple service dependency ordering through `depends_on`.
- Treat `profiles` as a filter.
- Convert long and short forms for environment, labels, ports, expose, volumes, networks, configs, secrets, and dependencies.
- Merge service ports, volumes, configs, and secrets by Compose-style unique resource keys. Ports use `ip`, `target`, `published`, and `protocol`; volumes, configs, and secrets use the effective container target path.
- Honor Compose `!reset` and `!override` merge tags when reducing ordered Compose file stacks into the normalized model.
- Represent top-level configs and secrets in the public model. File-backed configs and secrets are planned as read-only Apple Container bind mounts; external, environment-backed, and inline sources emit diagnostics until Apple Container has an equivalent resource API.
- Preserve service labels in the public model and plan them as Apple Container run labels, while rejecting the Compose-reserved `com.docker.compose` label prefix with structured diagnostics.
- Preserve service `extra_hosts` in the public model and emit planner diagnostics while Apple Container host-alias support is unavailable or unverified.
- Preserve service `expose` in the public model as internal-only service ports. Do not map it to host publishing flags; emit planner diagnostics so users understand it was retained without changing host access.
- Preserve service `privileged` in the public model and emit planner diagnostics for `true` values while Apple Container elevated-privilege support is unavailable or unverified.
- Preserve service `security_opt` in the public model with duplicate-free sequence merging and emit planner diagnostics while Apple Container security-option support is unavailable or unverified.
- Preserve service `container_name` in the public model and use it as the Apple Container ID for `up`, `start`, `stop`, `restart`, `logs`, `down`, and readiness metadata. Invalid names and effective-name collisions, including explicit names colliding with generated project/service names, emit structured diagnostics.
- Preserve service `hostname` in the public model, validate RFC 1123 format, and emit planner diagnostics while Apple Container hostname argument support is unavailable or unverified.
- Preserve service `domainname` in the public model, validate RFC 1123 format, and emit planner diagnostics while Apple Container domain-name argument support is unavailable or unverified.
- Attach services without explicit `networks` and without `network_mode` to Compose's implicit `default` network, synthesizing the top-level default network when needed.
- Preserve top-level network definition metadata in the public model, including custom names, external lookup names, driver fields, attachable mode, IPv4/IPv6 toggles, and IPAM config. Map custom and external lookup names to Apple Container network create/delete and service attachment arguments, map internal mode and labels to network creation, and emit planner diagnostics for the remaining metadata.
- Preserve top-level volume definition metadata in the public model, including custom names, external lookup names, driver fields, and driver options. Map custom and external lookup names to Apple Container volume create/delete and service mount arguments, map labels to volume creation, and emit planner diagnostics for driver metadata.
- Preserve service network long-syntax attachment options in the public model, including aliases, interface names, static addresses, link-local IPs, per-network MAC addresses, driver options, gateway priority, and connection priority. Continue planning network attachments by name and emit planner diagnostics for the unmapped attachment options.
- Preserve service `network_mode` in the public model, reject Compose files that also set service `networks`, and emit planner diagnostics while Apple Container network-mode argument support is unavailable or unverified.
- Treat `service:<name>` namespace references in `network_mode`, `pid`, and `ipc` as implicit dependencies for selected-service expansion and execution graph ordering while the namespace-sharing flags remain diagnostic-only.
- Preserve service `mac_address` in the public model, validate common MAC address forms, and emit planner diagnostics while Apple Container MAC-address argument support is unavailable or unverified.
- Preserve service `pid` mode in the public model and emit planner diagnostics while Apple Container PID namespace argument support is unavailable or unverified.
- Preserve service `ipc` mode in the public model and emit planner diagnostics while Apple Container IPC namespace argument support is unavailable or unverified.
- Preserve service `uts` mode in the public model and emit planner diagnostics while Apple Container UTS namespace argument support is unavailable or unverified.
- Preserve service `userns_mode` in the public model and emit planner diagnostics while Apple Container user-namespace argument support is unavailable or unverified.
- Preserve service `isolation` in the public model and emit planner diagnostics while Apple Container isolation-mode support is unavailable or unverified.
- Preserve service `cgroup` namespace mode in the public model, validate `host` and `private`, and emit planner diagnostics while Apple Container cgroup namespace argument support is unavailable or unverified.
- Preserve service `cgroup_parent` in the public model and emit planner diagnostics while Apple Container parent-cgroup argument support is unavailable or unverified.
- Preserve service `device_cgroup_rules` entries in the public model and emit planner diagnostics while Apple Container device-cgroup rule support is unavailable or unverified.
- Preserve service `devices` entries, including CDI selector strings, in the public model and emit planner diagnostics while Apple Container device mapping support is unavailable or unverified.
- Preserve service `gpus` requests, including `all` and list-form device requests, in the public model and emit planner diagnostics while Apple Container GPU allocation support is unavailable or unverified.
- Preserve service `group_add` entries in the public model and emit planner diagnostics while Apple Container supplemental group support is unavailable or unverified.
- Preserve service `sysctls` entries from map or list syntax in the public model and emit planner diagnostics while Apple Container sysctl support is unavailable or unverified.
- Preserve service `oom_kill_disable` and `oom_score_adj` in the public model, validate `oom_score_adj` within Compose's `[-1000, 1000]` range, and emit planner diagnostics while Apple Container OOM-control support is unavailable or unverified.
- Preserve service `pids_limit` in the public model, accept Compose's `-1` unlimited value while rejecting lower limits, and emit planner diagnostics while Apple Container PID-limit support is unavailable or unverified.
- Preserve service `logging` driver/options in the public model and emit planner diagnostics while Apple Container logging-driver support is unavailable or unverified.
- Preserve service `runtime`, `scale`, `storage_opt`, and `use_api_socket` in the public model, validate non-negative `scale`, and emit planner diagnostics while Apple Container runtime selection, replica planning, storage options, and engine API socket delegation are unavailable or unverified.
- Preserve service lifecycle hooks, `post_start`, `pre_start`, and `pre_stop`, in the public model, validate required `post_start` and `pre_stop` commands, and emit planner diagnostics while Apple Container lifecycle execution, ephemeral pre-start containers, and hook failure behavior are unavailable or unverified.
- Preserve service `provider` in the public model with required provider `type` and stringified provider `options`. Plan provider-backed services as delegated diagnostic commands so dependency ordering remains visible, and fail execution before invoking Apple Container until provider lifecycle delegation is available.
- Preserve service `credential_spec` in the public model for Compose gMSA-style `file`, `registry`, and `config` declarations, and emit planner diagnostics while Apple Container managed-service-account credential support is unavailable or unverified.
- Preserve service `volumes_from` entries in the public model, treat service references as implicit startup dependencies, leave `container:` references external, and emit planner diagnostics while Apple Container volume inheritance support is unavailable or unverified.
- Preserve top-level `models` definitions and service `models` grants in the public model. Service grants support Compose short syntax plus long syntax `endpoint_var` and `model_var`, and emit planner diagnostics while Apple Container model-runner environment wiring is unavailable or unverified.
- Preserve service `deploy` metadata in the public model, including replication, placement, resource, restart, and rolling update policy fields, and emit planner diagnostics while Apple Container orchestration behavior is unavailable or unverified.
- Preserve service `develop.watch` rules in the public model, including source paths, actions, target paths, include/ignore filters, initial sync, and `sync+exec` command metadata. Emit planner diagnostics while Apple Container file sync, rebuild, restart, and exec workflows are unavailable or unverified.
- Preserve service `links` and `external_links` in the public model. Treat `links` service names as implicit startup dependencies, and emit planner diagnostics while Apple Container link aliases and external platform lookups are unavailable or unverified.
- Resolve service `label_file` entries relative to the Compose source path, preserve the file list, merge labels in Compose precedence order, and feed the resulting labels into the existing Apple Container `--label` mapping.
- Preserve service `annotations` and explicit `attach` settings in the public model, and emit planner diagnostics while Apple Container annotations and log-collection behavior are unavailable or unverified.
- Preserve service `blkio_config` in the public model with typed block I/O weight and device rate entries, and emit planner diagnostics while Apple Container block I/O controls are unavailable or unverified.
- Preserve service CPU scheduler fields `cpu_count`, `cpu_percent`, `cpu_shares`, `cpu_period`, `cpu_quota`, `cpu_rt_runtime`, `cpu_rt_period`, and `cpuset` in the public model, and emit planner diagnostics while Apple Container CPU scheduler controls are unavailable or unverified.
- Preserve service `mem_reservation` and `mem_swappiness` in the public model, validate `mem_swappiness` within Compose's `[0, 100]` range, and emit planner diagnostics while Apple Container memory-reservation and swap-tuning support is unavailable or unverified.
- Preserve service `healthcheck` definitions in the public model and emit planner diagnostics while Apple Container run-argument mapping is unavailable. `depends_on: condition: service_healthy` warns when the dependency has no enabled healthcheck in the active Compose model.
- Map Apple Container run-compatible service options, including `init`, `stdin_open`, `tty`, `read_only`, `cap_add`, `cap_drop`, DNS settings, `shm_size`, `tmpfs`, and `ulimits`, while keeping unsupported kernel, security, and namespace options diagnostic-only.
- Preserve `stop_signal` and `stop_grace_period` in the public model and map them to per-service `container stop --signal` and `--time` arguments for `stop`, `restart`, and `down`. Invalid duration strings remain visible and emit command diagnostics.
- Preserve Compose `build` string/object syntax in the public model and plan supported options as `container build` before service `run` commands. Inline Dockerfiles are represented as generated files with deterministic paths and passed through Apple Container `--file`; the execution runner materializes those files before invoking the build. Build secrets backed by local files or host environment variables map to Apple Container `--secret` flags; external build secrets and unsupported secret metadata emit diagnostics. Build fields without Apple Container equivalents yet, including additional contexts, cache hints, entitlements, extra hosts, isolation, build network mode, privileged mode, shared-memory size, SSH mounts, provenance, SBOM settings, and ulimits, remain visible in the public model and emit planner diagnostics. Build-only services receive a deterministic local image tag, `<project>_<service>:latest`, so `container-desktop` can preview and execute build/run pairs without requiring an explicit `image`.
- Preserve service-level `pull_policy` in the public model. Static plans map `pull_policy: always` to `container image pull` before `run` and keep `pull_policy: build` as explicit build precedence; cache-age and missing-image policies remain visible with diagnostics for services that also declare `build`, because Docker Compose's conditional pull-then-build fallback is not yet representable as a static command sequence.
- Emit a stable JSON planning envelope with schema version, project metadata, runtime target, executable name, operation name, selected service targets, diagnostics, command argument arrays, optional runtime status, and an optional execution graph. Current emitted plan/report schema version is `1.8.0`; the embedded graph schema is `1.1.0`.
- Plan `down` as service container stop/delete plus project-defined non-external network deletion. Keep named volumes by default and delete project-defined non-external named volumes only when `--volumes` / `ContainerComposePlanRequest.removeVolumes` is set.
- Plan `run` as a one-off `container run` command using the selected service model, with dependency service start-up by default, build/pull prerequisites, generated `<project>_<service>_run_1` names, command/entrypoint/env/user/workdir overrides, `--rm`, `--no-deps`, `--service-ports`, and explicit published ports. Service ports stay unpublished by default to match Docker Compose `run`.
- Plan `create` as stopped service containers through `container create`, using the same service dependency closure, build/pull prerequisites, project resource creation, generated names, and service option mapping as `up`, while omitting detached startup.
- Plan `push` as service-scoped `container image push` commands for services with explicit `image` values. `--include-deps` expands selected services through their dependency closure, `--quiet` maps to `--progress none`, and `--ignore-push-failures` emits a diagnostic until execution can continue after failed push commands.
- Plan `images` as `container image list`, forwarding Apple Container's `--format`, `--quiet`, and `--verbose` flags. Emit diagnostics because Docker Compose scopes image output to created Compose containers and optional services, while Apple Container image listing is currently runtime-wide.
- Plan `ps` as `container list`, preserving selected service targets in the planning envelope for app previews while emitting diagnostics because Apple Container listing is currently runtime-wide and cannot filter by Compose project or service.
- Plan `kill` as service-scoped `container kill` commands using effective container names and optional signal forwarding.
- Plan `rm` as service-scoped `container delete` commands for stopped service containers. `--stop` prepends service-aware stop commands, while Docker Compose's confirmation-only `--force` has no Apple Container argument mapping and `--volumes` emits a diagnostic because anonymous volume cleanup is not exposed by `container delete`.
- Plan `exec` as a single service-scoped `container exec` command with Compose's default interactive and TTY behavior. Map detach, environment values, env files, user, workdir, and replica index where Apple Container has direct flags; keep Docker Compose `--privileged` as an explicit diagnostic because Apple Container exec does not expose an equivalent.
- Plan `cp` as a single `container copy` command by rewriting exactly one `SERVICE:PATH` endpoint to the effective Apple container name. Map Compose `--index` to generated replica names and emit diagnostics for `--archive`, `--follow-link`, and `--all`, which Apple Container copy does not expose.
- Accept `pause` and `unpause` service targeting and emit service-scoped diagnostic planned actions. The execution runner treats those actions as unsupported before invoking Apple Container until real pause primitives are verified.
- Accept `attach SERVICE` and preserve Docker Compose attach options for service index, stdin attachment, signal proxying, and detach keys. The execution runner treats attach actions as unsupported before invoking Apple Container until interactive stream semantics are verified.
- Accept `wait [SERVICE...]` and preserve Docker Compose stop-wait intent, including `--down-project`. This remains distinct from `up --wait`, which drives dependency readiness checks before executing dependent start commands.
- Accept `scale SERVICE=REPLICAS...` and preserve Docker Compose replica-count intent, including `--no-deps`. This is distinct from service-model `scale` and `deploy.replicas` preservation: the command records an imperative scale request, but execution remains blocked until Apple Container replica orchestration is verified.
- Resolve `port` from the normalized Compose model instead of invoking Apple Container. `ComposePortResolver` maps `SERVICE PRIVATE_PORT` plus protocol to declared published host endpoints and emits an index diagnostic because static model resolution does not inspect runtime replica state.
- Plan `top` as one `container exec <service-container> ps` command per selected service. Keep a command diagnostic because Docker Compose reports engine-side process information while Apple Container currently exposes a useful in-container process fallback through exec.
- Plan `stats` as project-scoped `container stats` calls using effective service container names, with `--no-stream` available for snapshot-style UI and CLI output.
- Emit optional JSON execution reports for runtime commands, including dry-run planned commands, optional runtime availability, per-command stdout/stderr/exit code, typed command error codes, cancelled/skipped commands, execution graph metadata, opt-in readiness wait results, and summary counts.
- Enforce readiness waits only when explicitly requested. `up --wait` and `ContainerComposeService.execute(..., enforceReadiness: true)` poll dependency requirements from the execution graph before running dependent commands; the default checker uses `container inspect`, and apps can inject a custom `ContainerReadinessChecking` implementation.
- Install the global CLI through thin SwiftPM-backed scripts that default to `$HOME/.local/bin` and avoid system-protected paths.
- Warn for unsupported fields such as `deploy`, unsupported `develop` subfields, unsupported build options, and platform-specific kernel/cgroup options.

Docker Compose itself delegates most of this to `compose-go`. Container Compose is Swift-first so it can be embedded by `container-desktop`, but `compose-go` and the Compose Specification remain the behavioral reference for merge order, include, extends, profile filtering, and environment precedence.

## Container Desktop Alignment

`container-desktop` already resolves and executes the Apple `container` CLI from the UI and has a lightweight Docker conversion service. Container Compose should become the shared Compose engine:

- Call `ContainerComposeService.loadProject(_:)` for UI inspection, `makePlan(_:)` for command previews, and `dryRun(_:)` for app-visible planned execution reports.
- Call `makeDesktopSnapshot(_:)` or `dryRunDesktopSnapshot(_:)` when the UI needs command-row view models with display strings, graph dependencies, readiness requirements, diagnostics, and optional execution results.
- Call `ContainerComposeService.runtimeStatus()` or attach an app-owned `AppleContainerRuntimeStatus` when the UI needs machine-readable runtime banners. Missing `container` is `unavailable` with issue code `containerCLIUnavailable`; version probe problems are `unknown` warnings so execution is not blocked solely by version output drift.
- Pass `AppleContainerExecutionControls` to runtime execution when the app needs command/readiness progress events or cancellation between commands and readiness waits.
- Keep `ContainerComposeCore` free of SwiftUI and process execution.
- Return `AppleContainerPlan` command arrays that `ContainerDesktop` can pass to its existing `ContainerCLIService` or another injected `ContainerCommandExecutor`.
- For targeted start workflows, pass service names through `ContainerComposePlanRequest.services`; `up` plans the selected services plus their transitive `depends_on` dependencies and records the requested names in `AppleContainerPlan.selectedServices`.
- Use `AppleContainerPlan.executionGraph` to render dependency ordering. Long-form `depends_on` metadata is preserved on graph edges, including `condition`, `restart`, and `required`. `emitReadinessChecks` adds started, healthy, or completed dependency requirements as metadata; `enforceReadiness` opts the runner into polling those requirements before each dependent command.
- Treat planned command arguments and graph `readiness.containerName` as authoritative container IDs. Re-deriving names from project and service labels will be wrong for services with explicit `container_name`.
- Keep remote include fetching behind an injectable `ComposeLoader` boundary so the app can enforce host allowlists, user consent, caching, and URL sanitization. Use `ComposeProject.remoteIncludes` to render provenance, cache status, and content byte counts in the app.
- Keep CLI discovery aligned with the app: `/usr/bin/container`, `/usr/local/bin/container`, `/opt/homebrew/bin/container`, `/opt/local/bin/container`, then `PATH`.
- Keep diagnostics and runtime failures structured so the app can render warnings beside generated commands and branch on `PlannedCommandExecution.errorCode` instead of parsing stderr.
- Use macOS 26 as the deployment floor to match the app and Apple Container.

## Next Milestones

The active implementation roadmap lives in [ROADMAP.md](ROADMAP.md). The next architecture milestone is direct `container-desktop` repository smoke coverage once a local checkout or CI fixture is available.
