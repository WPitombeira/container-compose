import Foundation

public struct ComposeProjectFilter: Sendable {
    public init() {}

    public func filter(_ project: ComposeProject, selectedServices: [String]) -> ComposeProject {
        guard !selectedServices.isEmpty else { return project }

        let selectedSet = Set(selectedServices)
        let servicesByName = Dictionary(uniqueKeysWithValues: project.services.map { ($0.name, $0) })
        var includedServices = Set<String>()
        var missingServices: [String] = []

        func include(_ serviceName: String) {
            guard !includedServices.contains(serviceName) else { return }
            guard let service = servicesByName[serviceName] else {
                missingServices.append(serviceName)
                return
            }
            includedServices.insert(serviceName)
            for dependency in service.dependsOn {
                include(dependency)
            }
        }

        for serviceName in selectedServices {
            include(serviceName)
        }

        let services = project.services.filter { includedServices.contains($0.name) }
        var diagnostics = project.diagnostics
        for serviceName in missingServices where selectedSet.contains(serviceName) {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(serviceName)",
                message: "Selected service is not present in the active Compose model. Check the service name or enabled profiles."
            ))
        }

        return ComposeProject(
            name: project.name,
            services: services,
            networks: filteredNetworks(project.networks, services: services),
            volumes: filteredVolumes(project.volumes, services: services),
            configs: filteredResources(project.configs, grants: services.flatMap(\.configs)),
            secrets: filteredResources(project.secrets, grants: services.flatMap(\.secrets)),
            models: filteredModels(project.models, services: services),
            remoteIncludes: project.remoteIncludes,
            diagnostics: diagnostics,
            sourcePath: project.sourcePath
        )
    }

    private func filteredNetworks(
        _ networks: [String: ComposeNetwork],
        services: [ComposeService]
    ) -> [String: ComposeNetwork] {
        let used = Set(services.flatMap { service in
            service.networks + service.networkAttachments.map(\.name)
        })
        return networks.filter { used.contains($0.key) }
    }

    private func filteredVolumes(
        _ volumes: [String: ComposeVolume],
        services: [ComposeService]
    ) -> [String: ComposeVolume] {
        let used = Set(services.flatMap { service in
            service.volumes.compactMap { namedVolumeName(from: $0, declaredVolumes: volumes) }
        })
        return volumes.filter { used.contains($0.key) }
    }

    private func filteredResources<T>(
        _ resources: [String: T],
        grants: [ComposeServiceResourceGrant]
    ) -> [String: T] {
        let used = Set(grants.map(\.source))
        return resources.filter { used.contains($0.key) }
    }

    private func filteredModels(
        _ models: [String: ComposeModelDefinition],
        services: [ComposeService]
    ) -> [String: ComposeModelDefinition] {
        let used = Set(services.flatMap(\.modelGrants).map(\.name))
        return models.filter { used.contains($0.key) }
    }

    private func namedVolumeName(
        from volume: String,
        declaredVolumes: [String: ComposeVolume]
    ) -> String? {
        let source = volume.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard declaredVolumes[source] != nil else { return nil }
        return source
    }
}
