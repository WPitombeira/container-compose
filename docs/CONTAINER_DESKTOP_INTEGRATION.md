# ContainerDesktop Integration

Container Compose is intended to be imported by `WPitombeira/container-desktop` as a Swift package. The app should depend on the `ContainerComposeCore` product and use the app-facing facade instead of shelling out to `container-compose`.

## Package Wiring

For a local development checkout:

```swift
.package(path: "../container-compose")
```

Then add the product to the app target:

```swift
.product(name: "ContainerComposeCore", package: "container-compose")
```

SwiftPM uses the path dependency identity (`container-compose`) in the `package:` argument even though the package declares its display name as `ContainerCompose`.

## Preview Flow

Use `makeDesktopSnapshot(_:)` for UI previews. It returns the normalized Compose project, the versioned plan envelope, and UI-ready command rows with display strings, diagnostics, execution-graph dependencies, and readiness requirements.

```swift
import ContainerComposeCore

let runtimeStatus = ContainerComposeService().runtimeStatus()
let service = ContainerComposeService(remoteIncludeResolver: { request in
    // Enforce app consent and host policy, then return network or cache content.
    let cached = try remoteIncludeCache.resolve(request.url)
    return ComposeLoader.RemoteIncludeResponse(
        yaml: cached.yaml,
        cacheKey: cached.key,
        cacheStatus: cached.wasHit ? .hit : .miss,
        source: cached.wasHit ? "container-desktop-cache" : "network"
    )
})
let snapshot = try service.makeDesktopSnapshot(.init(
    operation: .up,
    files: [composePath],
    projectDirectory: projectDirectory,
    projectName: projectName,
    profiles: activeProfiles,
    allowRemoteIncludes: false,
    emitReadinessChecks: true,
    runtimeStatus: runtimeStatus,
    detach: true
))

if snapshot.runtimeStatus?.availability == .unavailable {
    print(snapshot.runtimeStatus?.issues ?? [])
}

for include in snapshot.project.remoteIncludes {
    print(include.url)
    print(include.cacheStatus)
    print(include.cacheKey ?? "")
}

for command in snapshot.commands {
    print(command.displayCommand)
    print(command.dependsOnCommandIndexes)
    print(command.readiness)
    print(command.generatedFiles)
}
```

## Pasted Compose YAML

ContainerDesktop's converter can route pasted Compose YAML text through the same desktop snapshot API without creating temporary files. Pass the text as `composeYAML`; Container Compose will parse it from memory and use `projectDirectory/compose.yaml` as the synthetic source path unless `composeYAMLSourcePath` is provided.

```swift
let snapshot = try service.makeDesktopSnapshot(.init(
    operation: .up,
    composeYAML: pastedComposeText,
    composeYAMLSourcePath: "snippets/pasted-compose.yaml",
    projectDirectory: projectDirectory,
    composeEnvFiles: selectedEnvFiles,
    projectName: "pasted-preview",
    detach: true
))

let commandLines = snapshot.commands.map(\.displayCommand)
let diagnostics = snapshot.diagnostics
```

Use `composeYAMLSourcePath` when pasted YAML should resolve relative `include`, `env_file`, or file-based `extends` paths from a known project subdirectory. Use `composeEnvFiles` when the app exposes alternate interpolation env-file selection; relative env-file paths resolve from the snippet source directory. If the converter is handling a plain `docker run` command, keep using ContainerDesktop's existing Docker conversion path and reserve Container Compose for Compose YAML text.

When the UI needs to preview a saved Compose file plus an unsaved pasted or edited override, pass ordered `ComposeSource` values through `composeSources`. File-backed sources use `path` only; in-memory sources set `yaml` and still provide a synthetic path so relative include, env, and extends resolution has a stable anchor.

```swift
let snapshot = try service.makeDesktopSnapshot(.init(
    operation: .up,
    composeSources: [
        ComposeSource(path: "compose.yaml"),
        ComposeSource(path: "snippets/pasted-override.yaml", yaml: pastedOverrideText)
    ],
    projectDirectory: projectDirectory,
    projectName: "mixed-preview",
    detach: true
))
```

## Dry-Run Flow

Use `dryRunDesktopSnapshot(_:)` when the UI needs the same command rows plus planned execution rows. Dry-runs never invoke the Apple `container` CLI.

```swift
let snapshot = try service.dryRunDesktopSnapshot(.init(
    operation: .up,
    files: [composePath],
    projectDirectory: projectDirectory,
    emitReadinessChecks: true
))

let plannedStatuses = snapshot.commands.compactMap(\.execution?.status)
```

## Runtime Execution

ContainerDesktop can keep its existing process service by adapting it to `ContainerCommandExecutor`. The adapter receives raw Apple `container` arguments without the executable name.

```swift
struct DesktopContainerExecutor: ContainerCommandExecutor {
    func execute(arguments: [String]) throws -> CommandExecutionResult {
        // Forward to the app's existing ContainerCLIService.
        // Return stdout, stderr, exitCode, and duration.
    }
}

let report = service.execute(
    plan: snapshot.plan,
    dryRun: false,
    executor: DesktopContainerExecutor(),
    enforceReadiness: true,
    readinessChecker: appReadinessChecker,
    controls: .init(
        isCancelled: { task.isCancelled },
        progress: { event in
            // Bridge command/readiness events into the app's observable state.
        }
    )
)
```

ContainerDesktop's current process bridge is asynchronous, so it can also adapt directly to `AsyncContainerCommandExecutor` without blocking the UI task that owns execution:

```swift
struct DesktopAsyncContainerExecutor: AsyncContainerCommandExecutor {
    let service: ContainerCLIService

    func execute(arguments: [String]) async throws -> CommandExecutionResult {
        let output = try await service.execute(arguments)
        return CommandExecutionResult(
            executablePath: "container",
            arguments: output.arguments,
            exitCode: Int32(output.exitCode),
            standardOutput: output.stdout,
            standardError: output.stderr,
            durationMilliseconds: Int(output.elapsed * 1000)
        )
    }
}

let report = await service.execute(
    plan: snapshot.plan,
    dryRun: false,
    executor: DesktopAsyncContainerExecutor(service: appContainerCLIService),
    enforceReadiness: true,
    controls: .init(
        isCancelled: { task.isCancelled },
        progress: { event in
            // Bridge command/readiness events into the app's observable state.
        }
    )
)
```

The default readiness checker uses `container inspect`; the app can inject its own `ContainerReadinessChecking` implementation when it needs a different health policy. `AppleContainerExecutionControls` emits command and readiness events, and cancellation is honored before the next command or readiness wait starts. The default readiness checker also exits early when its controls become cancelled between polls.

Use `ContainerComposeService.runtimeStatus()` or an app-owned `AppleContainerRuntimeStatus` before execution when the UI needs a hard-stop banner for missing Apple Container support. The status is additive on `ContainerComposePlanRequest`, `AppleContainerPlan`, `AppleContainerExecutionReport`, and `ContainerComposeDesktopSnapshot`. Missing `container` resolves to `availability == .unavailable` with issue code `containerCLIUnavailable`; version probe failures are `unknown` warnings so a present runtime is not blocked only because its version output changed.

Use `ContainerComposeMetadata.currentVersionInfo` when the app needs to compare Container Compose tool metadata or schema versions before decoding persisted plans, reports, graphs, or runtime-status payloads. This keeps Container Desktop aligned with the same version contract used by `container-compose version --format json`.

Execution failures keep the compatibility `error` string, but also expose `PlannedCommandExecution.errorCode` for app logic. Current codes include `containerCLIUnavailable`, `processFailed`, `nonZeroExit`, `readinessFailed`, `readinessTimedOut`, `readinessCancelled`, `executionCancelled`, and `skippedPreviousFailure`.

When a planned command contains `generatedFiles`, the default execution runner writes those files before invoking the command and removes them after the command finishes. This is used for Compose `build.dockerfile_inline`, where previews show the deterministic generated Dockerfile path and runtime execution materializes the file for Apple `container build --file`.

Remote includes stay behind the app-owned resolver. `ComposeLoader.RemoteIncludeRequest` includes the original URL, sanitized URL, parent include source, and include stack; `ComposeLoader.RemoteIncludeResponse` returns YAML plus optional cache metadata. Container Compose records successful remote resolutions on `ComposeProject.remoteIncludes` without implementing its own network consent or cache storage.

## Stable Handoff Types

- `ComposeProject`: normalized Compose model for outline/detail views.
- `ComposeProject.remoteIncludes`: remote include provenance and app-supplied cache metadata.
- `ContainerComposeVersionInfo`: tool, command, package, runtime target, integration surface, and schema-version metadata.
- `AppleContainerPlan`: schema-versioned command plan for previews and persistence.
- `AppleContainerRuntimeStatus`: optional runtime availability, resolved executable path, version text, and typed issue codes for app banners.
- `PlannedCommand.generatedFiles`: app-materialized files such as inline Dockerfiles needed before running a planned Apple Container command.
- `ContainerComposeDesktopSnapshot`: project, plan, optional dry-run report, and UI command rows.
- `ContainerComposeDesktopCommandPreview`: one row per planned command, including display command, generated files, graph dependencies, readiness requirements, diagnostics, and optional execution result.
- `AppleContainerExecutionReport`: schema-versioned execution result with optional runtime status, typed command error codes, and `readinessResults`.
- `AppleContainerExecutionControls`: progress and cancellation hooks for app-owned runtime execution.
