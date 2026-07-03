public struct ContainerComposeSchemaVersions: Codable, Equatable, Sendable {
    public var plan: String
    public var executionReport: String
    public var executionGraph: String
    public var runtimeStatus: String

    public init(
        plan: String = ContainerComposeMetadata.planSchemaVersion,
        executionReport: String = ContainerComposeMetadata.executionReportSchemaVersion,
        executionGraph: String = ContainerComposeMetadata.executionGraphSchemaVersion,
        runtimeStatus: String = ContainerComposeMetadata.runtimeStatusSchemaVersion
    ) {
        self.plan = plan
        self.executionReport = executionReport
        self.executionGraph = executionGraph
        self.runtimeStatus = runtimeStatus
    }
}

public struct ContainerComposeVersionInfo: Codable, Equatable, Sendable {
    public var name: String
    public var packageName: String
    public var commandName: String
    public var version: String
    public var runtimeTarget: String
    public var containerDesktopIntegration: String
    public var schemas: ContainerComposeSchemaVersions

    public init(
        name: String = ContainerComposeMetadata.productName,
        packageName: String = ContainerComposeMetadata.packageName,
        commandName: String = ContainerComposeMetadata.commandName,
        version: String = ContainerComposeMetadata.toolVersion,
        runtimeTarget: String = ContainerComposeMetadata.runtimeTarget,
        containerDesktopIntegration: String = ContainerComposeMetadata.containerDesktopIntegration,
        schemas: ContainerComposeSchemaVersions = .init()
    ) {
        self.name = name
        self.packageName = packageName
        self.commandName = commandName
        self.version = version
        self.runtimeTarget = runtimeTarget
        self.containerDesktopIntegration = containerDesktopIntegration
        self.schemas = schemas
    }
}

public enum ContainerComposeMetadata {
    public static let productName = "Container Compose"
    public static let packageName = "ContainerCompose"
    public static let commandName = "container-compose"
    public static let toolVersion = "0.1.0"
    public static let runtimeTarget = "apple-container"
    public static let containerDesktopIntegration = "ContainerComposeCore"

    public static let planSchemaVersion = "1.8.0"
    public static let executionReportSchemaVersion = "1.8.0"
    public static let executionGraphSchemaVersion = "1.1.0"
    public static let runtimeStatusSchemaVersion = "1.0.0"

    public static let currentVersionInfo = ContainerComposeVersionInfo()
}
