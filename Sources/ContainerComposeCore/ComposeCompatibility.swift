import Foundation

public enum ComposeCompatibilityStatus: String, Codable, CaseIterable, Sendable {
    case mapped
    case preservedDiagnostic
    case rejectedDiagnostic
    case unsupported
}

public enum ComposeCompatibilityArea: String, Codable, CaseIterable, Sendable {
    case loader
    case planner
    case runtime
    case integration
}

public struct ComposeCompatibilityEntry: Codable, Equatable, Sendable {
    public var composePath: String
    public var status: ComposeCompatibilityStatus
    public var area: ComposeCompatibilityArea
    public var note: String

    public init(
        composePath: String,
        status: ComposeCompatibilityStatus,
        area: ComposeCompatibilityArea,
        note: String
    ) {
        self.composePath = composePath
        self.status = status
        self.area = area
        self.note = note
    }
}

public struct ComposeCompatibilityMatrix: Codable, Equatable, Sendable {
    public var generatedFrom: String
    public var entries: [ComposeCompatibilityEntry]

    public init(generatedFrom: String, entries: [ComposeCompatibilityEntry]) {
        self.generatedFrom = generatedFrom
        self.entries = entries
    }

    public static let current = ComposeCompatibilityMatrix(
        generatedFrom: "ContainerComposeCore support declarations",
        entries: [
            .init(composePath: "name", status: .mapped, area: .loader, note: "Parsed as the normalized project name."),
            .init(composePath: "include", status: .mapped, area: .loader, note: "Local includes are resolved; remote includes require explicit opt-in and an app-owned resolver."),
            .init(composePath: "services.*.image", status: .mapped, area: .planner, note: "Planned as the image argument for Apple Container run/create/pull/push workflows."),
            .init(composePath: "services.*.build", status: .mapped, area: .planner, note: "String and object syntax are parsed; supported options plan container build commands."),
            .init(composePath: "services.*.build.extra_hosts", status: .preservedDiagnostic, area: .planner, note: "Build host aliases are preserved without Apple Container build-argument mapping until runtime support is verified."),
            .init(composePath: "services.*.command", status: .mapped, area: .planner, note: "Mapped to Apple Container command arguments."),
            .init(composePath: "services.*.entrypoint", status: .mapped, area: .planner, note: "Mapped to Apple Container entrypoint arguments."),
            .init(composePath: "services.*.environment", status: .mapped, area: .planner, note: "Mapped to repeated Apple Container environment arguments."),
            .init(composePath: "services.*.env_file", status: .mapped, area: .planner, note: "String and long syntax are preserved; optional missing files are skipped and non-default formats warn."),
            .init(composePath: "services.*.extends", status: .mapped, area: .loader, note: "Same-file and file-based service inheritance is resolved before service parsing."),
            .init(composePath: "services.*.ports", status: .mapped, area: .planner, note: "Mapped to Apple Container publish arguments using Compose merge keys."),
            .init(composePath: "services.*.expose", status: .preservedDiagnostic, area: .planner, note: "Preserved as internal-only ports without publishing host ports."),
            .init(composePath: "services.*.volumes", status: .mapped, area: .planner, note: "Bind and named-volume references are planned as Apple Container volume arguments where supported."),
            .init(composePath: "services.*.volumes_from", status: .preservedDiagnostic, area: .planner, note: "Service references contribute startup dependencies; volume inheritance remains diagnostic-only."),
            .init(composePath: "services.*.networks", status: .mapped, area: .planner, note: "Project networks are created and service attachments are planned where Apple Container supports them."),
            .init(composePath: "services.*.networks.*", status: .preservedDiagnostic, area: .planner, note: "Long-syntax network attachment options are preserved; aliases, static addresses, interface names, and priorities are not mapped yet."),
            .init(composePath: "services.*.network_mode", status: .preservedDiagnostic, area: .planner, note: "Rejected when combined with networks; otherwise preserved until Apple Container behavior is verified."),
            .init(composePath: "services.*.network_mode + services.*.networks", status: .rejectedDiagnostic, area: .loader, note: "Compose forbids network_mode together with service networks."),
            .init(composePath: "services.*.depends_on", status: .mapped, area: .planner, note: "Dependency ordering, long-form metadata, and optional readiness requirements are preserved."),
            .init(composePath: "services.* namespace service:{name}", status: .mapped, area: .loader, note: "network_mode, pid, and ipc service references contribute dependency ordering."),
            .init(composePath: "services.*.profiles", status: .mapped, area: .loader, note: "Profile filtering follows Compose-style targeted service activation."),
            .init(composePath: "services.*.configs", status: .mapped, area: .planner, note: "File-backed configs map to read-only bind mounts; other sources remain diagnostic-only."),
            .init(composePath: "services.*.secrets", status: .mapped, area: .planner, note: "File-backed secrets map to read-only bind mounts; other sources remain diagnostic-only."),
            .init(composePath: "services.*.healthcheck", status: .preservedDiagnostic, area: .planner, note: "Healthcheck metadata and depends_on health conditions are preserved; run-argument mapping is diagnostic-only."),
            .init(composePath: "services.*.extends healthcheck disablement", status: .rejectedDiagnostic, area: .loader, note: "An extending service cannot newly disable healthchecks unless the referenced service also disables them."),
            .init(composePath: "services.*.labels", status: .mapped, area: .planner, note: "Map and list syntax are planned as Apple Container labels, except the reserved Compose prefix is rejected."),
            .init(composePath: "services.*.labels.com.docker.compose.*", status: .rejectedDiagnostic, area: .loader, note: "The Compose-reserved label prefix is rejected and is not passed to Apple Container."),
            .init(composePath: "services.*.label_file", status: .mapped, area: .loader, note: "Label files are resolved relative to the Compose source and merged before planning labels."),
            .init(composePath: "services.*.annotations", status: .preservedDiagnostic, area: .planner, note: "Preserved until Apple Container annotation behavior is verified."),
            .init(composePath: "services.*.attach", status: .preservedDiagnostic, area: .planner, note: "attach=false is preserved and warned because log collection is runtime/app-specific."),
            .init(composePath: "services.*.deploy", status: .preservedDiagnostic, area: .planner, note: "Deployment metadata is preserved; orchestration, placement, resource reservation, and rolling updates are not mapped."),
            .init(composePath: "services.*.deploy.endpoint_mode", status: .preservedDiagnostic, area: .planner, note: "Endpoint mode is preserved without Apple Container orchestration mapping."),
            .init(composePath: "services.*.deploy.labels", status: .preservedDiagnostic, area: .planner, note: "Deployment labels are preserved separately from service container labels."),
            .init(composePath: "services.*.deploy.mode", status: .preservedDiagnostic, area: .planner, note: "Replication mode is preserved without static Apple Container replica orchestration."),
            .init(composePath: "services.*.deploy.placement", status: .preservedDiagnostic, area: .planner, note: "Placement constraints and preferences are preserved without Apple Container scheduler mapping."),
            .init(composePath: "services.*.deploy.replicas", status: .preservedDiagnostic, area: .planner, note: "Replica counts are preserved without static multi-container planning."),
            .init(composePath: "services.*.deploy.resources", status: .preservedDiagnostic, area: .planner, note: "Deploy resource limits and reservations are preserved without Apple Container orchestration mapping."),
            .init(composePath: "services.*.deploy.resources.reservations.devices", status: .preservedDiagnostic, area: .planner, note: "Deploy device reservations are preserved without Apple Container scheduler or device-allocation mapping."),
            .init(composePath: "services.*.deploy.resources.reservations.generic_resources", status: .preservedDiagnostic, area: .planner, note: "Generic resource reservations are preserved without Apple Container scheduler mapping."),
            .init(composePath: "services.*.deploy.restart_policy", status: .preservedDiagnostic, area: .planner, note: "Deploy restart policies are preserved without orchestrator-level restart management."),
            .init(composePath: "services.*.deploy.rollback_config", status: .preservedDiagnostic, area: .planner, note: "Rollback update policy is preserved without Apple Container rolling-update orchestration."),
            .init(composePath: "services.*.deploy.update_config", status: .preservedDiagnostic, area: .planner, note: "Rolling update policy is preserved without Apple Container rolling-update orchestration."),
            .init(composePath: "services.*.develop", status: .preservedDiagnostic, area: .planner, note: "Watch metadata is preserved; file sync, rebuild, restart, and exec workflows are not mapped yet."),
            .init(composePath: "services.*.provider", status: .preservedDiagnostic, area: .runtime, note: "Provider metadata is preserved and plans delegated diagnostic commands that fail before invoking Apple Container."),
            .init(composePath: "services.*.credential_spec", status: .preservedDiagnostic, area: .planner, note: "gMSA credential declarations are preserved without Apple Container mapping."),
            .init(composePath: "services.*.container_name", status: .mapped, area: .planner, note: "Used as the effective Apple Container ID across lifecycle commands."),
            .init(composePath: "services.*.hostname", status: .preservedDiagnostic, area: .planner, note: "Validated and preserved until Apple Container hostname support is verified."),
            .init(composePath: "services.*.domainname", status: .preservedDiagnostic, area: .planner, note: "Validated and preserved until Apple Container domain-name support is verified."),
            .init(composePath: "services.*.mac_address", status: .preservedDiagnostic, area: .planner, note: "Validated and preserved until Apple Container MAC address support is verified."),
            .init(composePath: "services.*.pid", status: .preservedDiagnostic, area: .planner, note: "Namespace mode is preserved without Apple Container mapping."),
            .init(composePath: "services.*.ipc", status: .preservedDiagnostic, area: .planner, note: "Namespace mode is preserved without Apple Container mapping."),
            .init(composePath: "services.*.uts", status: .preservedDiagnostic, area: .planner, note: "Namespace mode is preserved without Apple Container mapping."),
            .init(composePath: "services.*.userns_mode", status: .preservedDiagnostic, area: .planner, note: "Namespace mode is preserved without Apple Container mapping."),
            .init(composePath: "services.*.isolation", status: .preservedDiagnostic, area: .planner, note: "Platform-specific isolation metadata is preserved without Apple Container mapping."),
            .init(composePath: "services.*.cgroup", status: .preservedDiagnostic, area: .planner, note: "Validated as host/private and preserved without Apple Container mapping."),
            .init(composePath: "services.*.cgroup_parent", status: .preservedDiagnostic, area: .planner, note: "Preserved without Apple Container mapping."),
            .init(composePath: "services.*.device_cgroup_rules", status: .preservedDiagnostic, area: .planner, note: "Preserved without Apple Container mapping."),
            .init(composePath: "services.*.devices", status: .preservedDiagnostic, area: .planner, note: "Host devices and CDI selector strings are preserved without Apple Container mapping."),
            .init(composePath: "services.*.gpus", status: .preservedDiagnostic, area: .planner, note: "GPU requests are preserved without Apple Container mapping."),
            .init(composePath: "services.*.group_add", status: .preservedDiagnostic, area: .planner, note: "Supplemental groups are preserved without Apple Container mapping."),
            .init(composePath: "services.*.sysctls", status: .preservedDiagnostic, area: .planner, note: "Sysctls are preserved without Apple Container mapping."),
            .init(composePath: "services.*.oom_kill_disable", status: .preservedDiagnostic, area: .planner, note: "OOM behavior is preserved without Apple Container mapping."),
            .init(composePath: "services.*.oom_score_adj", status: .preservedDiagnostic, area: .planner, note: "Validated against Compose range and preserved without Apple Container mapping."),
            .init(composePath: "services.*.pids_limit", status: .preservedDiagnostic, area: .planner, note: "Validated and preserved without Apple Container mapping."),
            .init(composePath: "services.*.logging", status: .preservedDiagnostic, area: .planner, note: "Logging driver/options are preserved without Apple Container mapping."),
            .init(composePath: "services.*.runtime", status: .preservedDiagnostic, area: .planner, note: "Runtime selection metadata is preserved without Apple Container mapping."),
            .init(composePath: "services.*.scale", status: .preservedDiagnostic, area: .planner, note: "Replica count metadata is preserved without static Apple Container replica planning."),
            .init(composePath: "services.*.storage_opt", status: .preservedDiagnostic, area: .planner, note: "Storage options are preserved without Apple Container mapping."),
            .init(composePath: "services.*.use_api_socket", status: .preservedDiagnostic, area: .planner, note: "Engine API socket delegation is preserved without Apple Container mapping."),
            .init(composePath: "services.*.post_start", status: .preservedDiagnostic, area: .planner, note: "Lifecycle hooks are preserved without Apple Container execution mapping."),
            .init(composePath: "services.*.pre_start", status: .preservedDiagnostic, area: .planner, note: "Lifecycle hooks are preserved without Apple Container execution mapping."),
            .init(composePath: "services.*.pre_stop", status: .preservedDiagnostic, area: .planner, note: "Lifecycle hooks are preserved without Apple Container execution mapping."),
            .init(composePath: "services.*.links", status: .preservedDiagnostic, area: .planner, note: "Service references contribute dependencies; aliases remain diagnostic-only."),
            .init(composePath: "services.*.external_links", status: .preservedDiagnostic, area: .planner, note: "External platform lookups are preserved without Apple Container mapping."),
            .init(composePath: "services.*.extra_hosts", status: .preservedDiagnostic, area: .planner, note: "Host aliases are preserved without Apple Container run-argument mapping until runtime support is verified."),
            .init(composePath: "services.*.privileged", status: .preservedDiagnostic, area: .planner, note: "Privileged mode is preserved but not mapped to Apple Container run arguments yet."),
            .init(composePath: "services.*.working_dir", status: .mapped, area: .planner, note: "Mapped to Apple Container workdir arguments."),
            .init(composePath: "services.*.user", status: .mapped, area: .planner, note: "Mapped to Apple Container user arguments."),
            .init(composePath: "services.*.platform", status: .mapped, area: .planner, note: "Mapped to Apple Container platform arguments where supported by the runtime."),
            .init(composePath: "services.*.cpus", status: .mapped, area: .planner, note: "Mapped to Apple Container CPU arguments."),
            .init(composePath: "services.*.mem_limit", status: .mapped, area: .planner, note: "Mapped to Apple Container memory arguments."),
            .init(composePath: "services.*.memswap_limit", status: .mapped, area: .planner, note: "Mapped through the same memory planning path as mem_limit."),
            .init(composePath: "services.*.mem_reservation", status: .preservedDiagnostic, area: .planner, note: "Preserved without Apple Container memory reservation mapping."),
            .init(composePath: "services.*.mem_swappiness", status: .preservedDiagnostic, area: .planner, note: "Validated and preserved without Apple Container swap tuning mapping."),
            .init(composePath: "services.*.init", status: .mapped, area: .planner, note: "Mapped to Apple Container init process arguments."),
            .init(composePath: "services.*.stdin_open", status: .mapped, area: .planner, note: "Mapped to interactive run behavior."),
            .init(composePath: "services.*.tty", status: .mapped, area: .planner, note: "Mapped to TTY run behavior."),
            .init(composePath: "services.*.read_only", status: .mapped, area: .planner, note: "Mapped to Apple Container read-only root filesystem arguments."),
            .init(composePath: "services.*.cap_add", status: .mapped, area: .planner, note: "Mapped to Apple Container capability arguments."),
            .init(composePath: "services.*.cap_drop", status: .mapped, area: .planner, note: "Mapped to Apple Container capability arguments."),
            .init(composePath: "services.*.security_opt", status: .preservedDiagnostic, area: .planner, note: "Security options are preserved without Apple Container mapping."),
            .init(composePath: "services.*.dns", status: .mapped, area: .planner, note: "Mapped to Apple Container DNS arguments."),
            .init(composePath: "services.*.dns_search", status: .mapped, area: .planner, note: "Mapped to Apple Container DNS search arguments."),
            .init(composePath: "services.*.dns_opt", status: .mapped, area: .planner, note: "Mapped to Apple Container DNS option arguments."),
            .init(composePath: "services.*.shm_size", status: .mapped, area: .planner, note: "Mapped to Apple Container shared memory size arguments."),
            .init(composePath: "services.*.tmpfs", status: .mapped, area: .planner, note: "Mapped to Apple Container tmpfs arguments."),
            .init(composePath: "services.*.ulimits", status: .mapped, area: .planner, note: "Mapped to Apple Container ulimit arguments."),
            .init(composePath: "services.*.restart", status: .mapped, area: .planner, note: "Preserved and mapped where Apple Container lifecycle commands can express it."),
            .init(composePath: "services.*.stop_signal", status: .mapped, area: .planner, note: "Mapped to Apple Container stop signal arguments."),
            .init(composePath: "services.*.stop_grace_period", status: .mapped, area: .planner, note: "Mapped to Apple Container stop timeout arguments when duration parsing succeeds."),
            .init(composePath: "services without networks", status: .mapped, area: .loader, note: "Services without networks or network_mode are attached to the implicit default network."),
            .init(composePath: "networks", status: .mapped, area: .planner, note: "Top-level networks are created unless marked external."),
            .init(composePath: "networks.*.name", status: .mapped, area: .planner, note: "Custom network names are used as the platform network name instead of project-scoped names."),
            .init(composePath: "networks.*", status: .preservedDiagnostic, area: .planner, note: "Network driver, driver options, attachable mode, IPv4/IPv6 toggles, and IPAM metadata are preserved but not fully mapped yet."),
            .init(composePath: "volumes", status: .mapped, area: .planner, note: "Top-level volumes are created and retained by default on down."),
            .init(composePath: "volumes.*.name", status: .mapped, area: .planner, note: "Custom volume names are used as the platform volume name instead of project-scoped names."),
            .init(composePath: "volumes.*.driver", status: .preservedDiagnostic, area: .planner, note: "Volume driver metadata is preserved but not mapped to Apple Container volume create arguments yet."),
            .init(composePath: "volumes.*.driver_opts", status: .preservedDiagnostic, area: .planner, note: "Volume driver options are preserved but not mapped to Apple Container volume create arguments yet."),
            .init(composePath: "configs", status: .mapped, area: .planner, note: "File-backed configs are planned as read-only bind mounts."),
            .init(composePath: "secrets", status: .mapped, area: .planner, note: "File-backed secrets are planned as read-only bind mounts."),
            .init(composePath: "models", status: .preservedDiagnostic, area: .planner, note: "Model definitions are preserved for app previews; model-runner wiring is not mapped yet."),
            .init(composePath: "x-*", status: .mapped, area: .loader, note: "Compose extension fields are ignored for unsupported-field diagnostics."),
            .init(composePath: "unknown Compose fields", status: .unsupported, area: .loader, note: "Unknown fields emit structured diagnostics instead of being silently treated as supported.")
        ].sorted { lhs, rhs in
            if lhs.status.rawValue == rhs.status.rawValue {
                return lhs.composePath < rhs.composePath
            }
            return lhs.status.rawValue < rhs.status.rawValue
        }
    )

    public func entries(
        with status: ComposeCompatibilityStatus? = nil,
        area: ComposeCompatibilityArea? = nil
    ) -> [ComposeCompatibilityEntry] {
        entries.filter { entry in
            (status == nil || entry.status == status)
                && (area == nil || entry.area == area)
        }
    }
}
