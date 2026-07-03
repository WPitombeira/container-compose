import Foundation

public struct ComposeProject: Codable, Equatable, Sendable {
    public var name: String
    public var services: [ComposeService]
    public var networks: [String: ComposeNetwork]
    public var volumes: [String: ComposeVolume]
    public var configs: [String: ComposeConfig]
    public var secrets: [String: ComposeSecret]
    public var models: [String: ComposeModelDefinition]
    public var remoteIncludes: [ComposeRemoteInclude]
    public var diagnostics: [ComposeDiagnostic]
    public var sourcePath: String

    public init(
        name: String,
        services: [ComposeService],
        networks: [String: ComposeNetwork] = [:],
        volumes: [String: ComposeVolume] = [:],
        configs: [String: ComposeConfig] = [:],
        secrets: [String: ComposeSecret] = [:],
        models: [String: ComposeModelDefinition] = [:],
        remoteIncludes: [ComposeRemoteInclude] = [],
        diagnostics: [ComposeDiagnostic] = [],
        sourcePath: String
    ) {
        self.name = name
        self.services = services
        self.networks = networks
        self.volumes = volumes
        self.configs = configs
        self.secrets = secrets
        self.models = models
        self.remoteIncludes = remoteIncludes
        self.diagnostics = diagnostics
        self.sourcePath = sourcePath
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case services
        case networks
        case volumes
        case configs
        case secrets
        case models
        case remoteIncludes
        case diagnostics
        case sourcePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        services = try container.decode([ComposeService].self, forKey: .services)
        networks = try container.decodeIfPresent([String: ComposeNetwork].self, forKey: .networks) ?? [:]
        volumes = try container.decodeIfPresent([String: ComposeVolume].self, forKey: .volumes) ?? [:]
        configs = try container.decodeIfPresent([String: ComposeConfig].self, forKey: .configs) ?? [:]
        secrets = try container.decodeIfPresent([String: ComposeSecret].self, forKey: .secrets) ?? [:]
        models = try container.decodeIfPresent([String: ComposeModelDefinition].self, forKey: .models) ?? [:]
        remoteIncludes = try container.decodeIfPresent([ComposeRemoteInclude].self, forKey: .remoteIncludes) ?? []
        diagnostics = try container.decodeIfPresent([ComposeDiagnostic].self, forKey: .diagnostics) ?? []
        sourcePath = try container.decode(String.self, forKey: .sourcePath)
    }
}

public enum ComposeRemoteIncludeCacheStatus: String, Codable, Equatable, Sendable {
    case unknown
    case bypassed
    case hit
    case miss
    case refreshed
    case stale
}

public struct ComposeRemoteInclude: Codable, Equatable, Sendable {
    public var url: String
    public var cacheKey: String?
    public var cacheStatus: ComposeRemoteIncludeCacheStatus
    public var source: String?
    public var contentLength: Int

    public init(
        url: String,
        cacheKey: String? = nil,
        cacheStatus: ComposeRemoteIncludeCacheStatus = .unknown,
        source: String? = nil,
        contentLength: Int
    ) {
        self.url = url
        self.cacheKey = cacheKey
        self.cacheStatus = cacheStatus
        self.source = source
        self.contentLength = contentLength
    }
}

public struct ComposeGPURequest: Codable, Equatable, Sendable {
    public var all: Bool
    public var devices: [ComposeGPUDeviceRequest]

    public init(all: Bool = false, devices: [ComposeGPUDeviceRequest] = []) {
        self.all = all
        self.devices = devices
    }
}

public struct ComposeGPUDeviceRequest: Codable, Equatable, Sendable {
    public var driver: String?
    public var count: String?
    public var deviceIDs: [String]
    public var capabilities: [String]
    public var options: [String: String]

    public init(
        driver: String? = nil,
        count: String? = nil,
        deviceIDs: [String] = [],
        capabilities: [String] = [],
        options: [String: String] = [:]
    ) {
        self.driver = driver
        self.count = count
        self.deviceIDs = deviceIDs
        self.capabilities = capabilities
        self.options = options
    }
}

public struct ComposeLogging: Codable, Equatable, Sendable {
    public var driver: String?
    public var options: [String: String]

    public init(driver: String? = nil, options: [String: String] = [:]) {
        self.driver = driver
        self.options = options
    }
}

public struct ComposeBlockIOConfig: Codable, Equatable, Sendable {
    public var weight: Int?
    public var weightDevice: [ComposeBlockIODeviceWeight]
    public var deviceReadBps: [ComposeBlockIODeviceRate]
    public var deviceReadIOps: [ComposeBlockIODeviceRate]
    public var deviceWriteBps: [ComposeBlockIODeviceRate]
    public var deviceWriteIOps: [ComposeBlockIODeviceRate]

    public init(
        weight: Int? = nil,
        weightDevice: [ComposeBlockIODeviceWeight] = [],
        deviceReadBps: [ComposeBlockIODeviceRate] = [],
        deviceReadIOps: [ComposeBlockIODeviceRate] = [],
        deviceWriteBps: [ComposeBlockIODeviceRate] = [],
        deviceWriteIOps: [ComposeBlockIODeviceRate] = []
    ) {
        self.weight = weight
        self.weightDevice = weightDevice
        self.deviceReadBps = deviceReadBps
        self.deviceReadIOps = deviceReadIOps
        self.deviceWriteBps = deviceWriteBps
        self.deviceWriteIOps = deviceWriteIOps
    }

    private enum CodingKeys: String, CodingKey {
        case weight
        case weightDevice
        case deviceReadBps
        case deviceReadIOps
        case deviceWriteBps
        case deviceWriteIOps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weight = try container.decodeIfPresent(Int.self, forKey: .weight)
        weightDevice = try container.decodeIfPresent([ComposeBlockIODeviceWeight].self, forKey: .weightDevice) ?? []
        deviceReadBps = try container.decodeIfPresent([ComposeBlockIODeviceRate].self, forKey: .deviceReadBps) ?? []
        deviceReadIOps = try container.decodeIfPresent([ComposeBlockIODeviceRate].self, forKey: .deviceReadIOps) ?? []
        deviceWriteBps = try container.decodeIfPresent([ComposeBlockIODeviceRate].self, forKey: .deviceWriteBps) ?? []
        deviceWriteIOps = try container.decodeIfPresent([ComposeBlockIODeviceRate].self, forKey: .deviceWriteIOps) ?? []
    }
}

public struct ComposeBlockIODeviceWeight: Codable, Equatable, Sendable {
    public var path: String
    public var weight: Int

    public init(path: String, weight: Int) {
        self.path = path
        self.weight = weight
    }
}

public struct ComposeBlockIODeviceRate: Codable, Equatable, Sendable {
    public var path: String
    public var rate: String

    public init(path: String, rate: String) {
        self.path = path
        self.rate = rate
    }
}

public struct ComposeLifecycleHook: Codable, Equatable, Sendable {
    public var command: [String]
    public var image: String?
    public var user: String?
    public var privileged: Bool?
    public var workingDirectory: String?
    public var environment: [String: String]
    public var perReplica: Bool?

    public init(
        command: [String] = [],
        image: String? = nil,
        user: String? = nil,
        privileged: Bool? = nil,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        perReplica: Bool? = nil
    ) {
        self.command = command
        self.image = image
        self.user = user
        self.privileged = privileged
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.perReplica = perReplica
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case image
        case user
        case privileged
        case workingDirectory
        case environment
        case perReplica
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decodeIfPresent([String].self, forKey: .command) ?? []
        image = try container.decodeIfPresent(String.self, forKey: .image)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        privileged = try container.decodeIfPresent(Bool.self, forKey: .privileged)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        perReplica = try container.decodeIfPresent(Bool.self, forKey: .perReplica)
    }
}

public struct ComposeProvider: Codable, Equatable, Sendable {
    public var type: String
    public var options: [String: String]

    public init(type: String, options: [String: String] = [:]) {
        self.type = type
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        options = try container.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
    }
}

public struct ComposeCredentialSpec: Codable, Equatable, Sendable {
    public var file: String?
    public var registry: String?
    public var config: String?

    public init(file: String? = nil, registry: String? = nil, config: String? = nil) {
        self.file = file
        self.registry = registry
        self.config = config
    }
}

public struct ComposeModelDefinition: Codable, Equatable, Sendable {
    public var name: String
    public var model: String?
    public var endpoint: String?
    public var options: [String: String]

    public init(name: String, model: String? = nil, endpoint: String? = nil, options: [String: String] = [:]) {
        self.name = name
        self.model = model
        self.endpoint = endpoint
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case model
        case endpoint
        case options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
        options = try container.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
    }
}

public struct ComposeServiceModelGrant: Codable, Equatable, Sendable {
    public var name: String
    public var endpointVariable: String?
    public var modelVariable: String?

    public init(name: String, endpointVariable: String? = nil, modelVariable: String? = nil) {
        self.name = name
        self.endpointVariable = endpointVariable
        self.modelVariable = modelVariable
    }
}

public struct ComposeEnvFile: Codable, Equatable, Sendable {
    public var path: String
    public var required: Bool
    public var format: String?

    public init(path: String, required: Bool = true, format: String? = nil) {
        self.path = path
        self.required = required
        self.format = format
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case required
        case format
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? true
        format = try container.decodeIfPresent(String.self, forKey: .format)
    }
}

public struct ComposeDevelop: Codable, Equatable, Sendable {
    public var watch: [ComposeDevelopWatchRule]

    public init(watch: [ComposeDevelopWatchRule] = []) {
        self.watch = watch
    }

    private enum CodingKeys: String, CodingKey {
        case watch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        watch = try container.decodeIfPresent([ComposeDevelopWatchRule].self, forKey: .watch) ?? []
    }
}

public struct ComposeDevelopWatchRule: Codable, Equatable, Sendable {
    public var path: String
    public var action: String
    public var target: String?
    public var ignore: [String]
    public var include: [String]
    public var initialSync: Bool?
    public var exec: ComposeDevelopExec?

    public init(
        path: String,
        action: String,
        target: String? = nil,
        ignore: [String] = [],
        include: [String] = [],
        initialSync: Bool? = nil,
        exec: ComposeDevelopExec? = nil
    ) {
        self.path = path
        self.action = action
        self.target = target
        self.ignore = ignore
        self.include = include
        self.initialSync = initialSync
        self.exec = exec
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case action
        case target
        case ignore
        case include
        case initialSync
        case exec
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        action = try container.decode(String.self, forKey: .action)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        ignore = try container.decodeIfPresent([String].self, forKey: .ignore) ?? []
        include = try container.decodeIfPresent([String].self, forKey: .include) ?? []
        initialSync = try container.decodeIfPresent(Bool.self, forKey: .initialSync)
        exec = try container.decodeIfPresent(ComposeDevelopExec.self, forKey: .exec)
    }
}

public struct ComposeDevelopExec: Codable, Equatable, Sendable {
    public var command: [String]
    public var user: String?
    public var privileged: Bool?
    public var workingDirectory: String?
    public var environment: [String: String]

    public init(
        command: [String] = [],
        user: String? = nil,
        privileged: Bool? = nil,
        workingDirectory: String? = nil,
        environment: [String: String] = [:]
    ) {
        self.command = command
        self.user = user
        self.privileged = privileged
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case user
        case privileged
        case workingDirectory
        case environment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decodeIfPresent([String].self, forKey: .command) ?? []
        user = try container.decodeIfPresent(String.self, forKey: .user)
        privileged = try container.decodeIfPresent(Bool.self, forKey: .privileged)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
    }
}

public struct ComposeDeploy: Codable, Equatable, Sendable {
    public var endpointMode: String?
    public var labels: [String]
    public var mode: String?
    public var replicas: Int?
    public var placement: ComposeDeployPlacement?
    public var resources: ComposeDeployResources?
    public var restartPolicy: ComposeDeployRestartPolicy?
    public var rollbackConfig: ComposeDeployUpdateConfig?
    public var updateConfig: ComposeDeployUpdateConfig?

    public init(
        endpointMode: String? = nil,
        labels: [String] = [],
        mode: String? = nil,
        replicas: Int? = nil,
        placement: ComposeDeployPlacement? = nil,
        resources: ComposeDeployResources? = nil,
        restartPolicy: ComposeDeployRestartPolicy? = nil,
        rollbackConfig: ComposeDeployUpdateConfig? = nil,
        updateConfig: ComposeDeployUpdateConfig? = nil
    ) {
        self.endpointMode = endpointMode
        self.labels = labels
        self.mode = mode
        self.replicas = replicas
        self.placement = placement
        self.resources = resources
        self.restartPolicy = restartPolicy
        self.rollbackConfig = rollbackConfig
        self.updateConfig = updateConfig
    }

    private enum CodingKeys: String, CodingKey {
        case endpointMode
        case labels
        case mode
        case replicas
        case placement
        case resources
        case restartPolicy
        case rollbackConfig
        case updateConfig
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpointMode = try container.decodeIfPresent(String.self, forKey: .endpointMode)
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        replicas = try container.decodeIfPresent(Int.self, forKey: .replicas)
        placement = try container.decodeIfPresent(ComposeDeployPlacement.self, forKey: .placement)
        resources = try container.decodeIfPresent(ComposeDeployResources.self, forKey: .resources)
        restartPolicy = try container.decodeIfPresent(ComposeDeployRestartPolicy.self, forKey: .restartPolicy)
        rollbackConfig = try container.decodeIfPresent(ComposeDeployUpdateConfig.self, forKey: .rollbackConfig)
        updateConfig = try container.decodeIfPresent(ComposeDeployUpdateConfig.self, forKey: .updateConfig)
    }
}

public struct ComposeDeployPlacement: Codable, Equatable, Sendable {
    public var constraints: [String]
    public var preferences: [[String: String]]

    public init(constraints: [String] = [], preferences: [[String: String]] = []) {
        self.constraints = constraints
        self.preferences = preferences
    }

    private enum CodingKeys: String, CodingKey {
        case constraints
        case preferences
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        constraints = try container.decodeIfPresent([String].self, forKey: .constraints) ?? []
        preferences = try container.decodeIfPresent([[String: String]].self, forKey: .preferences) ?? []
    }
}

public struct ComposeDeployResources: Codable, Equatable, Sendable {
    public var limits: ComposeDeployResourceSpec?
    public var reservations: ComposeDeployResourceSpec?

    public init(limits: ComposeDeployResourceSpec? = nil, reservations: ComposeDeployResourceSpec? = nil) {
        self.limits = limits
        self.reservations = reservations
    }
}

public struct ComposeDeployResourceSpec: Codable, Equatable, Sendable {
    public var cpus: String?
    public var memory: String?
    public var pids: Int?
    public var devices: [ComposeDeployDeviceReservation]
    public var genericResources: [ComposeDeployGenericResource]

    public init(
        cpus: String? = nil,
        memory: String? = nil,
        pids: Int? = nil,
        devices: [ComposeDeployDeviceReservation] = [],
        genericResources: [ComposeDeployGenericResource] = []
    ) {
        self.cpus = cpus
        self.memory = memory
        self.pids = pids
        self.devices = devices
        self.genericResources = genericResources
    }

    private enum CodingKeys: String, CodingKey {
        case cpus
        case memory
        case pids
        case devices
        case genericResources
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpus = try container.decodeIfPresent(String.self, forKey: .cpus)
        memory = try container.decodeIfPresent(String.self, forKey: .memory)
        pids = try container.decodeIfPresent(Int.self, forKey: .pids)
        devices = try container.decodeIfPresent([ComposeDeployDeviceReservation].self, forKey: .devices) ?? []
        genericResources = try container.decodeIfPresent(
            [ComposeDeployGenericResource].self,
            forKey: .genericResources
        ) ?? []
    }
}

public struct ComposeDeployGenericResource: Codable, Equatable, Sendable {
    public var discreteResourceSpec: ComposeDeployGenericResourceSpec?
    public var namedResourceSpec: ComposeDeployGenericResourceSpec?

    public init(
        discreteResourceSpec: ComposeDeployGenericResourceSpec? = nil,
        namedResourceSpec: ComposeDeployGenericResourceSpec? = nil
    ) {
        self.discreteResourceSpec = discreteResourceSpec
        self.namedResourceSpec = namedResourceSpec
    }

    private enum CodingKeys: String, CodingKey {
        case discreteResourceSpec
        case namedResourceSpec
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        discreteResourceSpec = try container.decodeIfPresent(
            ComposeDeployGenericResourceSpec.self,
            forKey: .discreteResourceSpec
        )
        namedResourceSpec = try container.decodeIfPresent(
            ComposeDeployGenericResourceSpec.self,
            forKey: .namedResourceSpec
        )
    }
}

public struct ComposeDeployGenericResourceSpec: Codable, Equatable, Sendable {
    public var kind: String?
    public var value: String?

    public init(kind: String? = nil, value: String? = nil) {
        self.kind = kind
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        if let string = try? container.decodeIfPresent(String.self, forKey: .value) {
            value = string
        } else if let int = try? container.decode(Int.self, forKey: .value) {
            value = String(int)
        } else if let double = try? container.decode(Double.self, forKey: .value) {
            value = String(double)
        } else if let bool = try? container.decode(Bool.self, forKey: .value) {
            value = bool ? "true" : "false"
        } else {
            value = nil
        }
    }
}

public struct ComposeDeployDeviceReservation: Codable, Equatable, Sendable {
    public var capabilities: [String]
    public var driver: String?
    public var count: String?
    public var deviceIDs: [String]
    public var options: [String: String]

    public init(
        capabilities: [String] = [],
        driver: String? = nil,
        count: String? = nil,
        deviceIDs: [String] = [],
        options: [String: String] = [:]
    ) {
        self.capabilities = capabilities
        self.driver = driver
        self.count = count
        self.deviceIDs = deviceIDs
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case capabilities
        case driver
        case count
        case deviceIDs
        case options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        driver = try container.decodeIfPresent(String.self, forKey: .driver)
        count = try container.decodeIfPresent(String.self, forKey: .count)
        deviceIDs = try container.decodeIfPresent([String].self, forKey: .deviceIDs) ?? []
        options = try container.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
    }
}

public struct ComposeDeployRestartPolicy: Codable, Equatable, Sendable {
    public var condition: String?
    public var delay: String?
    public var maxAttempts: Int?
    public var window: String?

    public init(condition: String? = nil, delay: String? = nil, maxAttempts: Int? = nil, window: String? = nil) {
        self.condition = condition
        self.delay = delay
        self.maxAttempts = maxAttempts
        self.window = window
    }
}

public struct ComposeDeployUpdateConfig: Codable, Equatable, Sendable {
    public var parallelism: Int?
    public var delay: String?
    public var failureAction: String?
    public var monitor: String?
    public var maxFailureRatio: String?
    public var order: String?

    public init(
        parallelism: Int? = nil,
        delay: String? = nil,
        failureAction: String? = nil,
        monitor: String? = nil,
        maxFailureRatio: String? = nil,
        order: String? = nil
    ) {
        self.parallelism = parallelism
        self.delay = delay
        self.failureAction = failureAction
        self.monitor = monitor
        self.maxFailureRatio = maxFailureRatio
        self.order = order
    }
}

public struct ComposeServiceNetworkAttachment: Codable, Equatable, Sendable {
    public var name: String
    public var aliases: [String]
    public var interfaceName: String?
    public var ipv4Address: String?
    public var ipv6Address: String?
    public var linkLocalIPs: [String]
    public var macAddress: String?
    public var driverOptions: [String: String]
    public var gatewayPriority: Int?
    public var priority: Int?

    public init(
        name: String,
        aliases: [String] = [],
        interfaceName: String? = nil,
        ipv4Address: String? = nil,
        ipv6Address: String? = nil,
        linkLocalIPs: [String] = [],
        macAddress: String? = nil,
        driverOptions: [String: String] = [:],
        gatewayPriority: Int? = nil,
        priority: Int? = nil
    ) {
        self.name = name
        self.aliases = aliases
        self.interfaceName = interfaceName
        self.ipv4Address = ipv4Address
        self.ipv6Address = ipv6Address
        self.linkLocalIPs = linkLocalIPs
        self.macAddress = macAddress
        self.driverOptions = driverOptions
        self.gatewayPriority = gatewayPriority
        self.priority = priority
    }

    public var hasOptions: Bool {
        !aliases.isEmpty
            || interfaceName != nil
            || ipv4Address != nil
            || ipv6Address != nil
            || !linkLocalIPs.isEmpty
            || macAddress != nil
            || !driverOptions.isEmpty
            || gatewayPriority != nil
            || priority != nil
    }
}

public struct ComposeService: Codable, Equatable, Sendable {
    public var name: String
    public var image: String?
    public var pullPolicy: String?
    public var build: ComposeBuild?
    public var command: [String]
    public var entrypoint: String?
    public var environment: [String: String]
    public var envFiles: [String]
    public var envFileEntries: [ComposeEnvFile]
    public var annotations: [String]
    public var attach: Bool?
    public var blockIOConfig: ComposeBlockIOConfig?
    public var ports: [String]
    public var exposedPorts: [String]
    public var volumes: [String]
    public var networks: [String]
    public var networkAttachments: [ComposeServiceNetworkAttachment]
    public var networkMode: String?
    public var pidMode: String?
    public var ipcMode: String?
    public var utsMode: String?
    public var usernsMode: String?
    public var isolation: String?
    public var cgroupMode: String?
    public var cgroupParent: String?
    public var deviceCgroupRules: [String]
    public var devices: [String]
    public var gpus: ComposeGPURequest?
    public var groupAdd: [String]
    public var sysctls: [String: String]
    public var oomKillDisable: Bool?
    public var oomScoreAdjustment: Int?
    public var pidsLimit: Int?
    public var logging: ComposeLogging?
    public var runtime: String?
    public var scale: Int?
    public var storageOptions: [String: String]
    public var useAPISocket: Bool?
    public var provider: ComposeProvider?
    public var credentialSpec: ComposeCredentialSpec?
    public var volumesFrom: [String]
    public var modelGrants: [ComposeServiceModelGrant]
    public var develop: ComposeDevelop?
    public var deploy: ComposeDeploy?
    public var postStartHooks: [ComposeLifecycleHook]
    public var preStartHooks: [ComposeLifecycleHook]
    public var preStopHooks: [ComposeLifecycleHook]
    public var links: [String]
    public var externalLinks: [String]
    public var dependsOn: [String]
    public var dependsOnMetadata: [String: ComposeServiceDependencyMetadata]
    public var healthcheck: ComposeHealthcheck?
    public var profiles: [String]
    public var configs: [ComposeServiceResourceGrant]
    public var secrets: [ComposeServiceResourceGrant]
    public var workingDirectory: String?
    public var user: String?
    public var platform: String?
    public var cpus: String?
    public var cpuCount: Int?
    public var cpuPercent: Int?
    public var cpuShares: Int?
    public var cpuPeriod: Int?
    public var cpuQuota: Int?
    public var cpuRTRuntime: String?
    public var cpuRTPeriod: String?
    public var cpuSet: String?
    public var memory: String?
    public var memoryReservation: String?
    public var memorySwappiness: Int?
    public var initProcess: Bool
    public var stdinOpen: Bool
    public var tty: Bool
    public var readOnly: Bool
    public var capAdd: [String]
    public var capDrop: [String]
    public var securityOptions: [String]
    public var dns: [String]
    public var dnsSearch: [String]
    public var dnsOptions: [String]
    public var shmSize: String?
    public var tmpfs: [String]
    public var ulimits: [String]
    public var restart: String?
    public var stopSignal: String?
    public var stopGracePeriod: String?
    public var labelFiles: [String]
    public var labels: [String]
    public var containerName: String?
    public var hostname: String?
    public var domainName: String?
    public var macAddress: String?
    public var extraHosts: [String]
    public var privileged: Bool?

    public init(
        name: String,
        image: String?,
        pullPolicy: String? = nil,
        build: ComposeBuild? = nil,
        command: [String] = [],
        entrypoint: String? = nil,
        environment: [String: String] = [:],
        envFiles: [String] = [],
        envFileEntries: [ComposeEnvFile] = [],
        annotations: [String] = [],
        attach: Bool? = nil,
        blockIOConfig: ComposeBlockIOConfig? = nil,
        ports: [String] = [],
        exposedPorts: [String] = [],
        volumes: [String] = [],
        networks: [String] = [],
        networkAttachments: [ComposeServiceNetworkAttachment] = [],
        networkMode: String? = nil,
        pidMode: String? = nil,
        ipcMode: String? = nil,
        utsMode: String? = nil,
        usernsMode: String? = nil,
        isolation: String? = nil,
        cgroupMode: String? = nil,
        cgroupParent: String? = nil,
        deviceCgroupRules: [String] = [],
        devices: [String] = [],
        gpus: ComposeGPURequest? = nil,
        groupAdd: [String] = [],
        sysctls: [String: String] = [:],
        oomKillDisable: Bool? = nil,
        oomScoreAdjustment: Int? = nil,
        pidsLimit: Int? = nil,
        logging: ComposeLogging? = nil,
        runtime: String? = nil,
        scale: Int? = nil,
        storageOptions: [String: String] = [:],
        useAPISocket: Bool? = nil,
        provider: ComposeProvider? = nil,
        credentialSpec: ComposeCredentialSpec? = nil,
        volumesFrom: [String] = [],
        modelGrants: [ComposeServiceModelGrant] = [],
        develop: ComposeDevelop? = nil,
        deploy: ComposeDeploy? = nil,
        postStartHooks: [ComposeLifecycleHook] = [],
        preStartHooks: [ComposeLifecycleHook] = [],
        preStopHooks: [ComposeLifecycleHook] = [],
        links: [String] = [],
        externalLinks: [String] = [],
        dependsOn: [String] = [],
        dependsOnMetadata: [String: ComposeServiceDependencyMetadata] = [:],
        healthcheck: ComposeHealthcheck? = nil,
        profiles: [String] = [],
        configs: [ComposeServiceResourceGrant] = [],
        secrets: [ComposeServiceResourceGrant] = [],
        workingDirectory: String? = nil,
        user: String? = nil,
        platform: String? = nil,
        cpus: String? = nil,
        cpuCount: Int? = nil,
        cpuPercent: Int? = nil,
        cpuShares: Int? = nil,
        cpuPeriod: Int? = nil,
        cpuQuota: Int? = nil,
        cpuRTRuntime: String? = nil,
        cpuRTPeriod: String? = nil,
        cpuSet: String? = nil,
        memory: String? = nil,
        memoryReservation: String? = nil,
        memorySwappiness: Int? = nil,
        initProcess: Bool = false,
        stdinOpen: Bool = false,
        tty: Bool = false,
        readOnly: Bool = false,
        capAdd: [String] = [],
        capDrop: [String] = [],
        securityOptions: [String] = [],
        dns: [String] = [],
        dnsSearch: [String] = [],
        dnsOptions: [String] = [],
        shmSize: String? = nil,
        tmpfs: [String] = [],
        ulimits: [String] = [],
        restart: String? = nil,
        stopSignal: String? = nil,
        stopGracePeriod: String? = nil,
        labelFiles: [String] = [],
        labels: [String] = [],
        containerName: String? = nil,
        hostname: String? = nil,
        domainName: String? = nil,
        macAddress: String? = nil,
        extraHosts: [String] = [],
        privileged: Bool? = nil
    ) {
        self.name = name
        self.image = image
        self.pullPolicy = pullPolicy
        self.build = build
        self.command = command
        self.entrypoint = entrypoint
        self.environment = environment
        self.envFiles = envFiles
        self.envFileEntries = envFileEntries
        self.annotations = annotations
        self.attach = attach
        self.blockIOConfig = blockIOConfig
        self.ports = ports
        self.exposedPorts = exposedPorts
        self.volumes = volumes
        self.networks = networks
        self.networkAttachments = networkAttachments.isEmpty
            ? networks.map { ComposeServiceNetworkAttachment(name: $0) }
            : networkAttachments
        self.networkMode = networkMode
        self.pidMode = pidMode
        self.ipcMode = ipcMode
        self.utsMode = utsMode
        self.usernsMode = usernsMode
        self.isolation = isolation
        self.cgroupMode = cgroupMode
        self.cgroupParent = cgroupParent
        self.deviceCgroupRules = deviceCgroupRules
        self.devices = devices
        self.gpus = gpus
        self.groupAdd = groupAdd
        self.sysctls = sysctls
        self.oomKillDisable = oomKillDisable
        self.oomScoreAdjustment = oomScoreAdjustment
        self.pidsLimit = pidsLimit
        self.logging = logging
        self.runtime = runtime
        self.scale = scale
        self.storageOptions = storageOptions
        self.useAPISocket = useAPISocket
        self.provider = provider
        self.credentialSpec = credentialSpec
        self.volumesFrom = volumesFrom
        self.modelGrants = modelGrants
        self.develop = develop
        self.deploy = deploy
        self.postStartHooks = postStartHooks
        self.preStartHooks = preStartHooks
        self.preStopHooks = preStopHooks
        self.links = links
        self.externalLinks = externalLinks
        self.dependsOn = dependsOn
        self.dependsOnMetadata = dependsOnMetadata.isEmpty ? Self.defaultDependsOnMetadata(for: dependsOn) : dependsOnMetadata
        self.healthcheck = healthcheck
        self.profiles = profiles
        self.configs = configs
        self.secrets = secrets
        self.workingDirectory = workingDirectory
        self.user = user
        self.platform = platform
        self.cpus = cpus
        self.cpuCount = cpuCount
        self.cpuPercent = cpuPercent
        self.cpuShares = cpuShares
        self.cpuPeriod = cpuPeriod
        self.cpuQuota = cpuQuota
        self.cpuRTRuntime = cpuRTRuntime
        self.cpuRTPeriod = cpuRTPeriod
        self.cpuSet = cpuSet
        self.memory = memory
        self.memoryReservation = memoryReservation
        self.memorySwappiness = memorySwappiness
        self.initProcess = initProcess
        self.stdinOpen = stdinOpen
        self.tty = tty
        self.readOnly = readOnly
        self.capAdd = capAdd
        self.capDrop = capDrop
        self.securityOptions = securityOptions
        self.dns = dns
        self.dnsSearch = dnsSearch
        self.dnsOptions = dnsOptions
        self.shmSize = shmSize
        self.tmpfs = tmpfs
        self.ulimits = ulimits
        self.restart = restart
        self.stopSignal = stopSignal
        self.stopGracePeriod = stopGracePeriod
        self.labelFiles = labelFiles
        self.labels = labels
        self.containerName = containerName
        self.hostname = hostname
        self.domainName = domainName
        self.macAddress = macAddress
        self.extraHosts = extraHosts
        self.privileged = privileged
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case image
        case pullPolicy
        case build
        case command
        case entrypoint
        case environment
        case envFiles
        case envFileEntries
        case annotations
        case attach
        case blockIOConfig
        case ports
        case exposedPorts
        case volumes
        case networks
        case networkAttachments
        case networkMode
        case pidMode
        case ipcMode
        case utsMode
        case usernsMode
        case isolation
        case cgroupMode
        case cgroupParent
        case deviceCgroupRules
        case devices
        case gpus
        case groupAdd
        case sysctls
        case oomKillDisable
        case oomScoreAdjustment
        case pidsLimit
        case logging
        case runtime
        case scale
        case storageOptions
        case useAPISocket
        case provider
        case credentialSpec
        case volumesFrom
        case modelGrants
        case develop
        case deploy
        case postStartHooks
        case preStartHooks
        case preStopHooks
        case links
        case externalLinks
        case dependsOn
        case dependsOnMetadata
        case healthcheck
        case profiles
        case configs
        case secrets
        case workingDirectory
        case user
        case platform
        case cpus
        case cpuCount
        case cpuPercent
        case cpuShares
        case cpuPeriod
        case cpuQuota
        case cpuRTRuntime
        case cpuRTPeriod
        case cpuSet
        case memory
        case memoryReservation
        case memorySwappiness
        case initProcess
        case stdinOpen
        case tty
        case readOnly
        case capAdd
        case capDrop
        case securityOptions
        case dns
        case dnsSearch
        case dnsOptions
        case shmSize
        case tmpfs
        case ulimits
        case restart
        case stopSignal
        case stopGracePeriod
        case labelFiles
        case labels
        case containerName
        case hostname
        case domainName
        case macAddress
        case extraHosts
        case privileged
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        image = try container.decodeIfPresent(String.self, forKey: .image)
        pullPolicy = try container.decodeIfPresent(String.self, forKey: .pullPolicy)
        build = try container.decodeIfPresent(ComposeBuild.self, forKey: .build)
        command = try container.decodeIfPresent([String].self, forKey: .command) ?? []
        entrypoint = try container.decodeIfPresent(String.self, forKey: .entrypoint)
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        envFiles = try container.decodeIfPresent([String].self, forKey: .envFiles) ?? []
        envFileEntries = try container.decodeIfPresent([ComposeEnvFile].self, forKey: .envFileEntries) ?? []
        annotations = try container.decodeIfPresent([String].self, forKey: .annotations) ?? []
        attach = try container.decodeIfPresent(Bool.self, forKey: .attach)
        blockIOConfig = try container.decodeIfPresent(ComposeBlockIOConfig.self, forKey: .blockIOConfig)
        ports = try container.decodeIfPresent([String].self, forKey: .ports) ?? []
        exposedPorts = try container.decodeIfPresent([String].self, forKey: .exposedPorts) ?? []
        volumes = try container.decodeIfPresent([String].self, forKey: .volumes) ?? []
        networks = try container.decodeIfPresent([String].self, forKey: .networks) ?? []
        networkAttachments = try container.decodeIfPresent(
            [ComposeServiceNetworkAttachment].self,
            forKey: .networkAttachments
        ) ?? networks.map { ComposeServiceNetworkAttachment(name: $0) }
        networkMode = try container.decodeIfPresent(String.self, forKey: .networkMode)
        pidMode = try container.decodeIfPresent(String.self, forKey: .pidMode)
        ipcMode = try container.decodeIfPresent(String.self, forKey: .ipcMode)
        utsMode = try container.decodeIfPresent(String.self, forKey: .utsMode)
        usernsMode = try container.decodeIfPresent(String.self, forKey: .usernsMode)
        isolation = try container.decodeIfPresent(String.self, forKey: .isolation)
        cgroupMode = try container.decodeIfPresent(String.self, forKey: .cgroupMode)
        cgroupParent = try container.decodeIfPresent(String.self, forKey: .cgroupParent)
        deviceCgroupRules = try container.decodeIfPresent([String].self, forKey: .deviceCgroupRules) ?? []
        devices = try container.decodeIfPresent([String].self, forKey: .devices) ?? []
        gpus = try container.decodeIfPresent(ComposeGPURequest.self, forKey: .gpus)
        groupAdd = try container.decodeIfPresent([String].self, forKey: .groupAdd) ?? []
        sysctls = try container.decodeIfPresent([String: String].self, forKey: .sysctls) ?? [:]
        oomKillDisable = try container.decodeIfPresent(Bool.self, forKey: .oomKillDisable)
        oomScoreAdjustment = try container.decodeIfPresent(Int.self, forKey: .oomScoreAdjustment)
        pidsLimit = try container.decodeIfPresent(Int.self, forKey: .pidsLimit)
        logging = try container.decodeIfPresent(ComposeLogging.self, forKey: .logging)
        runtime = try container.decodeIfPresent(String.self, forKey: .runtime)
        scale = try container.decodeIfPresent(Int.self, forKey: .scale)
        storageOptions = try container.decodeIfPresent([String: String].self, forKey: .storageOptions) ?? [:]
        useAPISocket = try container.decodeIfPresent(Bool.self, forKey: .useAPISocket)
        provider = try container.decodeIfPresent(ComposeProvider.self, forKey: .provider)
        credentialSpec = try container.decodeIfPresent(ComposeCredentialSpec.self, forKey: .credentialSpec)
        volumesFrom = try container.decodeIfPresent([String].self, forKey: .volumesFrom) ?? []
        modelGrants = try container.decodeIfPresent([ComposeServiceModelGrant].self, forKey: .modelGrants) ?? []
        develop = try container.decodeIfPresent(ComposeDevelop.self, forKey: .develop)
        deploy = try container.decodeIfPresent(ComposeDeploy.self, forKey: .deploy)
        postStartHooks = try container.decodeIfPresent([ComposeLifecycleHook].self, forKey: .postStartHooks) ?? []
        preStartHooks = try container.decodeIfPresent([ComposeLifecycleHook].self, forKey: .preStartHooks) ?? []
        preStopHooks = try container.decodeIfPresent([ComposeLifecycleHook].self, forKey: .preStopHooks) ?? []
        links = try container.decodeIfPresent([String].self, forKey: .links) ?? []
        externalLinks = try container.decodeIfPresent([String].self, forKey: .externalLinks) ?? []
        dependsOn = try container.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
        dependsOnMetadata = try container.decodeIfPresent(
            [String: ComposeServiceDependencyMetadata].self,
            forKey: .dependsOnMetadata
        ) ?? Self.defaultDependsOnMetadata(for: dependsOn)
        healthcheck = try container.decodeIfPresent(ComposeHealthcheck.self, forKey: .healthcheck)
        profiles = try container.decodeIfPresent([String].self, forKey: .profiles) ?? []
        configs = try container.decodeIfPresent([ComposeServiceResourceGrant].self, forKey: .configs) ?? []
        secrets = try container.decodeIfPresent([ComposeServiceResourceGrant].self, forKey: .secrets) ?? []
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        cpus = try container.decodeIfPresent(String.self, forKey: .cpus)
        cpuCount = try container.decodeIfPresent(Int.self, forKey: .cpuCount)
        cpuPercent = try container.decodeIfPresent(Int.self, forKey: .cpuPercent)
        cpuShares = try container.decodeIfPresent(Int.self, forKey: .cpuShares)
        cpuPeriod = try container.decodeIfPresent(Int.self, forKey: .cpuPeriod)
        cpuQuota = try container.decodeIfPresent(Int.self, forKey: .cpuQuota)
        cpuRTRuntime = try container.decodeIfPresent(String.self, forKey: .cpuRTRuntime)
        cpuRTPeriod = try container.decodeIfPresent(String.self, forKey: .cpuRTPeriod)
        cpuSet = try container.decodeIfPresent(String.self, forKey: .cpuSet)
        memory = try container.decodeIfPresent(String.self, forKey: .memory)
        memoryReservation = try container.decodeIfPresent(String.self, forKey: .memoryReservation)
        memorySwappiness = try container.decodeIfPresent(Int.self, forKey: .memorySwappiness)
        initProcess = try container.decodeIfPresent(Bool.self, forKey: .initProcess) ?? false
        stdinOpen = try container.decodeIfPresent(Bool.self, forKey: .stdinOpen) ?? false
        tty = try container.decodeIfPresent(Bool.self, forKey: .tty) ?? false
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        capAdd = try container.decodeIfPresent([String].self, forKey: .capAdd) ?? []
        capDrop = try container.decodeIfPresent([String].self, forKey: .capDrop) ?? []
        securityOptions = try container.decodeIfPresent([String].self, forKey: .securityOptions) ?? []
        dns = try container.decodeIfPresent([String].self, forKey: .dns) ?? []
        dnsSearch = try container.decodeIfPresent([String].self, forKey: .dnsSearch) ?? []
        dnsOptions = try container.decodeIfPresent([String].self, forKey: .dnsOptions) ?? []
        shmSize = try container.decodeIfPresent(String.self, forKey: .shmSize)
        tmpfs = try container.decodeIfPresent([String].self, forKey: .tmpfs) ?? []
        ulimits = try container.decodeIfPresent([String].self, forKey: .ulimits) ?? []
        restart = try container.decodeIfPresent(String.self, forKey: .restart)
        stopSignal = try container.decodeIfPresent(String.self, forKey: .stopSignal)
        stopGracePeriod = try container.decodeIfPresent(String.self, forKey: .stopGracePeriod)
        labelFiles = try container.decodeIfPresent([String].self, forKey: .labelFiles) ?? []
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        containerName = try container.decodeIfPresent(String.self, forKey: .containerName)
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
        domainName = try container.decodeIfPresent(String.self, forKey: .domainName)
        macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress)
        extraHosts = try container.decodeIfPresent([String].self, forKey: .extraHosts) ?? []
        privileged = try container.decodeIfPresent(Bool.self, forKey: .privileged)
    }

    private static func defaultDependsOnMetadata(for dependencies: [String]) -> [String: ComposeServiceDependencyMetadata] {
        dependencies.reduce(into: [String: ComposeServiceDependencyMetadata]()) { result, dependency in
            result[dependency] = result[dependency] ?? ComposeServiceDependencyMetadata()
        }
    }
}

public struct ComposeHealthcheck: Codable, Equatable, Sendable {
    public var test: [String]
    public var interval: String?
    public var timeout: String?
    public var retries: Int?
    public var startPeriod: String?
    public var startInterval: String?
    public var disabled: Bool

    public init(
        test: [String] = [],
        interval: String? = nil,
        timeout: String? = nil,
        retries: Int? = nil,
        startPeriod: String? = nil,
        startInterval: String? = nil,
        disabled: Bool = false
    ) {
        self.test = test
        self.interval = interval
        self.timeout = timeout
        self.retries = retries
        self.startPeriod = startPeriod
        self.startInterval = startInterval
        self.disabled = disabled
    }

    private enum CodingKeys: String, CodingKey {
        case test
        case interval
        case timeout
        case retries
        case startPeriod
        case startInterval
        case disabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        test = try container.decodeIfPresent([String].self, forKey: .test) ?? []
        interval = try container.decodeIfPresent(String.self, forKey: .interval)
        timeout = try container.decodeIfPresent(String.self, forKey: .timeout)
        retries = try container.decodeIfPresent(Int.self, forKey: .retries)
        startPeriod = try container.decodeIfPresent(String.self, forKey: .startPeriod)
        startInterval = try container.decodeIfPresent(String.self, forKey: .startInterval)
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
    }
}

public struct ComposeBuild: Codable, Equatable, Sendable {
    public var context: String
    public var additionalContexts: [String]
    public var dockerfile: String?
    public var dockerfileInline: String?
    public var args: [String]
    public var cacheFrom: [String]
    public var cacheTo: [String]
    public var entitlements: [String]
    public var extraHosts: [String]
    public var isolation: String?
    public var labels: [String]
    public var network: String?
    public var privileged: Bool?
    public var secrets: [ComposeServiceResourceGrant]
    public var shmSize: String?
    public var ssh: [String]
    public var target: String?
    public var tags: [String]
    public var noCache: Bool
    public var pull: Bool
    public var platforms: [String]
    public var provenance: String?
    public var sbom: String?
    public var ulimits: [String]

    public init(
        context: String = ".",
        additionalContexts: [String] = [],
        dockerfile: String? = nil,
        dockerfileInline: String? = nil,
        args: [String] = [],
        cacheFrom: [String] = [],
        cacheTo: [String] = [],
        entitlements: [String] = [],
        extraHosts: [String] = [],
        isolation: String? = nil,
        labels: [String] = [],
        network: String? = nil,
        privileged: Bool? = nil,
        secrets: [ComposeServiceResourceGrant] = [],
        shmSize: String? = nil,
        ssh: [String] = [],
        target: String? = nil,
        tags: [String] = [],
        noCache: Bool = false,
        pull: Bool = false,
        platforms: [String] = [],
        provenance: String? = nil,
        sbom: String? = nil,
        ulimits: [String] = []
    ) {
        self.context = context
        self.additionalContexts = additionalContexts
        self.dockerfile = dockerfile
        self.dockerfileInline = dockerfileInline
        self.args = args
        self.cacheFrom = cacheFrom
        self.cacheTo = cacheTo
        self.entitlements = entitlements
        self.extraHosts = extraHosts
        self.isolation = isolation
        self.labels = labels
        self.network = network
        self.privileged = privileged
        self.secrets = secrets
        self.shmSize = shmSize
        self.ssh = ssh
        self.target = target
        self.tags = tags
        self.noCache = noCache
        self.pull = pull
        self.platforms = platforms
        self.provenance = provenance
        self.sbom = sbom
        self.ulimits = ulimits
    }

    private enum CodingKeys: String, CodingKey {
        case context
        case additionalContexts
        case dockerfile
        case dockerfileInline
        case args
        case cacheFrom
        case cacheTo
        case entitlements
        case extraHosts
        case isolation
        case labels
        case network
        case privileged
        case secrets
        case shmSize
        case ssh
        case target
        case tags
        case noCache
        case pull
        case platforms
        case provenance
        case sbom
        case ulimits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        context = try container.decodeIfPresent(String.self, forKey: .context) ?? "."
        additionalContexts = try container.decodeIfPresent([String].self, forKey: .additionalContexts) ?? []
        dockerfile = try container.decodeIfPresent(String.self, forKey: .dockerfile)
        dockerfileInline = try container.decodeIfPresent(String.self, forKey: .dockerfileInline)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        cacheFrom = try container.decodeIfPresent([String].self, forKey: .cacheFrom) ?? []
        cacheTo = try container.decodeIfPresent([String].self, forKey: .cacheTo) ?? []
        entitlements = try container.decodeIfPresent([String].self, forKey: .entitlements) ?? []
        extraHosts = try container.decodeIfPresent([String].self, forKey: .extraHosts) ?? []
        isolation = try container.decodeIfPresent(String.self, forKey: .isolation)
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        network = try container.decodeIfPresent(String.self, forKey: .network)
        privileged = try container.decodeIfPresent(Bool.self, forKey: .privileged)
        secrets = try container.decodeIfPresent([ComposeServiceResourceGrant].self, forKey: .secrets) ?? []
        shmSize = try container.decodeIfPresent(String.self, forKey: .shmSize)
        ssh = try container.decodeIfPresent([String].self, forKey: .ssh) ?? []
        target = try container.decodeIfPresent(String.self, forKey: .target)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        noCache = try container.decodeIfPresent(Bool.self, forKey: .noCache) ?? false
        pull = try container.decodeIfPresent(Bool.self, forKey: .pull) ?? false
        platforms = try container.decodeIfPresent([String].self, forKey: .platforms) ?? []
        provenance = try container.decodeIfPresent(String.self, forKey: .provenance)
        sbom = try container.decodeIfPresent(String.self, forKey: .sbom)
        ulimits = try container.decodeIfPresent([String].self, forKey: .ulimits) ?? []
    }
}

public enum ComposeDependencyCondition: String, Codable, Sendable {
    case serviceStarted = "service_started"
    case serviceHealthy = "service_healthy"
    case serviceCompletedSuccessfully = "service_completed_successfully"
}

public struct ComposeServiceDependencyMetadata: Codable, Equatable, Sendable {
    public var condition: ComposeDependencyCondition
    public var restart: Bool
    public var required: Bool

    public init(
        condition: ComposeDependencyCondition = .serviceStarted,
        restart: Bool = false,
        required: Bool = true
    ) {
        self.condition = condition
        self.restart = restart
        self.required = required
    }

    private enum CodingKeys: String, CodingKey {
        case condition
        case restart
        case required
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        condition = try container.decodeIfPresent(ComposeDependencyCondition.self, forKey: .condition) ?? .serviceStarted
        restart = try container.decodeIfPresent(Bool.self, forKey: .restart) ?? false
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? true
    }
}

public struct ComposeServiceResourceGrant: Codable, Equatable, Sendable {
    public var source: String
    public var target: String
    public var uid: String?
    public var gid: String?
    public var mode: String?

    public init(
        source: String,
        target: String,
        uid: String? = nil,
        gid: String? = nil,
        mode: String? = nil
    ) {
        self.source = source
        self.target = target
        self.uid = uid
        self.gid = gid
        self.mode = mode
    }
}

public struct ComposeNetworkIPAMConfig: Codable, Equatable, Sendable {
    public var subnet: String?
    public var ipRange: String?
    public var gateway: String?
    public var auxAddresses: [String: String]

    public init(
        subnet: String? = nil,
        ipRange: String? = nil,
        gateway: String? = nil,
        auxAddresses: [String: String] = [:]
    ) {
        self.subnet = subnet
        self.ipRange = ipRange
        self.gateway = gateway
        self.auxAddresses = auxAddresses
    }
}

public struct ComposeNetworkIPAM: Codable, Equatable, Sendable {
    public var driver: String?
    public var options: [String: String]
    public var config: [ComposeNetworkIPAMConfig]

    public init(
        driver: String? = nil,
        options: [String: String] = [:],
        config: [ComposeNetworkIPAMConfig] = []
    ) {
        self.driver = driver
        self.options = options
        self.config = config
    }

    public var hasOptions: Bool {
        driver != nil || !options.isEmpty || !config.isEmpty
    }
}

public struct ComposeNetwork: Codable, Equatable, Sendable {
    public var name: String
    public var customName: String?
    public var external: Bool
    public var externalName: String?
    public var internalOnly: Bool
    public var attachable: Bool?
    public var driver: String?
    public var driverOptions: [String: String]
    public var enableIPv4: Bool?
    public var enableIPv6: Bool?
    public var ipam: ComposeNetworkIPAM?
    public var labels: [String]

    public init(
        name: String,
        customName: String? = nil,
        external: Bool = false,
        externalName: String? = nil,
        internalOnly: Bool = false,
        attachable: Bool? = nil,
        driver: String? = nil,
        driverOptions: [String: String] = [:],
        enableIPv4: Bool? = nil,
        enableIPv6: Bool? = nil,
        ipam: ComposeNetworkIPAM? = nil,
        labels: [String] = []
    ) {
        self.name = name
        self.customName = customName
        self.external = external
        self.externalName = externalName
        self.internalOnly = internalOnly
        self.attachable = attachable
        self.driver = driver
        self.driverOptions = driverOptions
        self.enableIPv4 = enableIPv4
        self.enableIPv6 = enableIPv6
        self.ipam = ipam
        self.labels = labels
    }

    public var hasUnmappedOptions: Bool {
        attachable != nil
            || driver != nil
            || !driverOptions.isEmpty
            || enableIPv4 != nil
            || enableIPv6 != nil
            || ipam?.hasOptions == true
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case customName
        case external
        case externalName
        case internalOnly
        case attachable
        case driver
        case driverOptions
        case enableIPv4
        case enableIPv6
        case ipam
        case labels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
        external = try container.decodeIfPresent(Bool.self, forKey: .external) ?? false
        externalName = try container.decodeIfPresent(String.self, forKey: .externalName)
        internalOnly = try container.decodeIfPresent(Bool.self, forKey: .internalOnly) ?? false
        attachable = try container.decodeIfPresent(Bool.self, forKey: .attachable)
        driver = try container.decodeIfPresent(String.self, forKey: .driver)
        driverOptions = try container.decodeIfPresent([String: String].self, forKey: .driverOptions) ?? [:]
        enableIPv4 = try container.decodeIfPresent(Bool.self, forKey: .enableIPv4)
        enableIPv6 = try container.decodeIfPresent(Bool.self, forKey: .enableIPv6)
        ipam = try container.decodeIfPresent(ComposeNetworkIPAM.self, forKey: .ipam)
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
    }
}

public struct ComposeConfig: Codable, Equatable, Sendable {
    public var name: String
    public var file: String?
    public var environment: String?
    public var content: String?
    public var external: Bool
    public var externalName: String?

    public init(
        name: String,
        file: String? = nil,
        environment: String? = nil,
        content: String? = nil,
        external: Bool = false,
        externalName: String? = nil
    ) {
        self.name = name
        self.file = file
        self.environment = environment
        self.content = content
        self.external = external
        self.externalName = externalName
    }
}

public struct ComposeSecret: Codable, Equatable, Sendable {
    public var name: String
    public var file: String?
    public var environment: String?
    public var external: Bool
    public var externalName: String?

    public init(
        name: String,
        file: String? = nil,
        environment: String? = nil,
        external: Bool = false,
        externalName: String? = nil
    ) {
        self.name = name
        self.file = file
        self.environment = environment
        self.external = external
        self.externalName = externalName
    }
}

public struct ComposeVolume: Codable, Equatable, Sendable {
    public var name: String
    public var customName: String?
    public var external: Bool
    public var externalName: String?
    public var driver: String?
    public var driverOptions: [String: String]
    public var labels: [String]

    public init(
        name: String,
        customName: String? = nil,
        external: Bool = false,
        externalName: String? = nil,
        driver: String? = nil,
        driverOptions: [String: String] = [:],
        labels: [String] = []
    ) {
        self.name = name
        self.customName = customName
        self.external = external
        self.externalName = externalName
        self.driver = driver
        self.driverOptions = driverOptions
        self.labels = labels
    }

    public var hasUnmappedOptions: Bool {
        driver != nil
            || !driverOptions.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case customName
        case external
        case externalName
        case driver
        case driverOptions
        case labels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
        external = try container.decodeIfPresent(Bool.self, forKey: .external) ?? false
        externalName = try container.decodeIfPresent(String.self, forKey: .externalName)
        driver = try container.decodeIfPresent(String.self, forKey: .driver)
        driverOptions = try container.decodeIfPresent([String: String].self, forKey: .driverOptions) ?? [:]
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
    }
}
