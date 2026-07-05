import XCTest
@testable import ContainerComposeCore

final class ComposeLoaderTests: XCTestCase {
    private func makeTemporaryWorkdir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-loader-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRemoteLoader(fixtures: [String: String], allowRemoteIncludes: Bool = true) -> ComposeLoader {
        ComposeLoader(allowRemoteIncludes: allowRemoteIncludes) { url in
            guard let yaml = fixtures[url.absoluteString] else {
                throw ComposeLoadError.fileNotFound([url.absoluteString])
            }
            return yaml
        }
    }

    func testLoadsCommonComposeSubset() throws {
        let yaml = """
        name: demo
        services:
          db:
            image: postgres:16
            environment:
              POSTGRES_PASSWORD: secret
            volumes:
              - db-data:/var/lib/postgresql/data
          web:
            image: nginx:alpine
            depends_on:
              - db
            ports:
              - "8080:80"
            networks:
              - front
        networks:
          front: {}
        volumes:
          db-data: {}
        """

        let project = try ComposeLoader().load(yaml: yaml, sourcePath: "/tmp/demo/compose.yaml")

        XCTAssertEqual(project.name, "demo")
        XCTAssertEqual(project.services.map(\.name), ["db", "web"])
        XCTAssertEqual(project.networks["front"]?.name, "front")
        XCTAssertEqual(project.volumes["db-data"]?.name, "db-data")
        XCTAssertTrue(project.diagnostics.isEmpty)
    }

    func testServicesWithoutNetworksUseImplicitDefaultNetwork() throws {
        let yaml = """
        services:
          web:
            image: nginx
          isolated:
            image: alpine
            network_mode: none
          explicit-empty:
            image: busybox
            networks: []
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })
        let isolated = try XCTUnwrap(project.services.first { $0.name == "isolated" })
        let explicitEmpty = try XCTUnwrap(project.services.first { $0.name == "explicit-empty" })

        XCTAssertEqual(web.networks, ["default"])
        XCTAssertEqual(web.networkAttachments, [ComposeServiceNetworkAttachment(name: "default")])
        XCTAssertEqual(project.networks["default"], ComposeNetwork(name: "default"))
        XCTAssertEqual(isolated.networks, [])
        XCTAssertEqual(explicitEmpty.networks, [])
        XCTAssertTrue(project.diagnostics.isEmpty)
    }

    func testImplicitDefaultNetworkUsesTopLevelDefaultDefinition() throws {
        let yaml = """
        services:
          web:
            image: nginx
        networks:
          default:
            name: shared_default
            labels:
              com.example.scope: dev
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let web = try XCTUnwrap(project.services.first)

        XCTAssertEqual(web.networks, ["default"])
        XCTAssertEqual(project.networks["default"]?.customName, "shared_default")
        XCTAssertEqual(project.networks["default"]?.labels, ["com.example.scope=dev"])
    }

    func testLoadsServiceNetworkLongSyntaxAttachments() throws {
        let yaml = """
        services:
          web:
            image: nginx
            networks:
              back:
                aliases:
                  - api.local
                interface_name: eth0
                ipv4_address: 172.16.238.10
                ipv6_address: 2001:3984:3989::10
                link_local_ips:
                  - 57.123.22.11
                mac_address: 02:42:ac:11:00:02
                driver_opts:
                  com.example.mode: fast
                gw_priority: 1
                priority: 10
                x-network-note: ignored
              front: {}
        networks:
          back: {}
          front: {}
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let service = try XCTUnwrap(project.services.first)

        XCTAssertEqual(service.networks, ["back", "front"])
        XCTAssertEqual(service.networkAttachments, [
            ComposeServiceNetworkAttachment(
                name: "back",
                aliases: ["api.local"],
                interfaceName: "eth0",
                ipv4Address: "172.16.238.10",
                ipv6Address: "2001:3984:3989::10",
                linkLocalIPs: ["57.123.22.11"],
                macAddress: "02:42:ac:11:00:02",
                driverOptions: ["com.example.mode": "fast"],
                gatewayPriority: 1,
                priority: 10
            ),
            ComposeServiceNetworkAttachment(name: "front")
        ])
        XCTAssertFalse(project.diagnostics.contains { $0.path.contains("x-") })
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.networks.back" })
    }

    func testInvalidServiceNetworkLongSyntaxProducesDiagnostics() throws {
        let yaml = """
        services:
          web:
            image: nginx
            networks:
              back:
                aliases:
                  bad: true
                mac_address: invalid
                gw_priority: high
                unknown: true
              front: true
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let service = try XCTUnwrap(project.services.first)

        XCTAssertEqual(service.networks, ["back", "front"])
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.web.networks.back.aliases"
            && $0.message == "Expected a string or list of strings."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.web.networks.back.mac_address"
            && $0.message == "mac_address must be a valid MAC address."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.web.networks.back.gw_priority"
            && $0.message == "Expected an integer value."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.web.networks.back.unknown"
            && $0.message == "Service network option is not implemented yet."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.web.networks.front"
            && $0.message == "Expected a mapping for service network options."
        })
    }

    func testMergesServiceNetworksAsUniqueByNetworkNameAcrossOrderedComposeFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: nginx
            networks:
              - front
              - back
        networks:
          front: {}
          back: {}
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          web:
            networks:
              - front
              - cache
        networks:
          cache: {}
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: [basePath.path, overridePath.path])
        let service = try XCTUnwrap(project.services.first)

        XCTAssertEqual(service.networks, ["front", "back", "cache"])
        XCTAssertEqual(service.networkAttachments, [
            ComposeServiceNetworkAttachment(name: "front"),
            ComposeServiceNetworkAttachment(name: "back"),
            ComposeServiceNetworkAttachment(name: "cache")
        ])
        XCTAssertEqual(Set(project.networks.keys), ["front", "back", "cache"])
        XCTAssertTrue(project.diagnostics.isEmpty)
    }

    func testMergesMixedServiceNetworkFormsPreservingLongOptionsAcrossOrderedComposeFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: nginx
            networks:
              front:
                aliases:
                  - app.local
                interface_name: eth0
                priority: 50
        networks:
          front: {}
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          web:
            networks:
              - front
              - back
        networks:
          back: {}
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: [basePath.path, overridePath.path])
        let service = try XCTUnwrap(project.services.first)
        let attachmentsByName = Dictionary(uniqueKeysWithValues: service.networkAttachments.map { ($0.name, $0) })

        XCTAssertEqual(Set(service.networks), ["front", "back"])
        XCTAssertEqual(attachmentsByName["front"], ComposeServiceNetworkAttachment(
            name: "front",
            aliases: ["app.local"],
            interfaceName: "eth0",
            priority: 50
        ))
        XCTAssertEqual(attachmentsByName["back"], ComposeServiceNetworkAttachment(name: "back"))
        XCTAssertTrue(project.diagnostics.isEmpty)
    }

    func testLoadsTopLevelNetworkOptions() throws {
        let yaml = """
        services:
          web:
            image: nginx
            networks:
              - front
        networks:
          front:
            name: shared_front
            driver: bridge
            driver_opts:
              com.example.mode: fast
            attachable: true
            enable_ipv4: false
            enable_ipv6: true
            internal: true
            labels:
              com.example.scope: dev
            ipam:
              driver: default
              options:
                com.example.ipam: enabled
              config:
                - subnet: 172.28.0.0/16
                  ip_range: 172.28.5.0/24
                  gateway: 172.28.5.254
                  aux_addresses:
                    host1: 172.28.1.5
            x-network-note: ignored
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let network = try XCTUnwrap(project.networks["front"])

        XCTAssertEqual(network.customName, "shared_front")
        XCTAssertEqual(network.driver, "bridge")
        XCTAssertEqual(network.driverOptions, ["com.example.mode": "fast"])
        XCTAssertEqual(network.attachable, true)
        XCTAssertEqual(network.enableIPv4, false)
        XCTAssertEqual(network.enableIPv6, true)
        XCTAssertEqual(network.internalOnly, true)
        XCTAssertEqual(network.labels, ["com.example.scope=dev"])
        XCTAssertEqual(network.ipam, ComposeNetworkIPAM(
            driver: "default",
            options: ["com.example.ipam": "enabled"],
            config: [
                ComposeNetworkIPAMConfig(
                    subnet: "172.28.0.0/16",
                    ipRange: "172.28.5.0/24",
                    gateway: "172.28.5.254",
                    auxAddresses: ["host1": "172.28.1.5"]
                )
            ]
        ))
        XCTAssertTrue(network.hasUnmappedOptions)
        XCTAssertFalse(project.diagnostics.contains { $0.path.contains("x-network-note") })
    }

    func testMergesNetworkIPAMConfigsBySubnetAcrossOrderedComposeFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: nginx
            networks:
              - front
        networks:
          front:
            ipam:
              config:
                - subnet: 172.28.0.0/16
                  ip_range: 172.28.5.0/24
                  gateway: 172.28.5.254
                  aux_addresses:
                    host1: 172.28.1.5
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        networks:
          front:
            ipam:
              config:
                - subnet: 172.28.0.0/16
                  gateway: 172.28.5.1
                  aux_addresses:
                    host2: 172.28.1.6
                - subnet: 172.29.0.0/16
                  gateway: 172.29.0.1
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: [basePath.path, overridePath.path])
        let network = try XCTUnwrap(project.networks["front"])

        XCTAssertEqual(network.ipam?.config, [
            ComposeNetworkIPAMConfig(
                subnet: "172.28.0.0/16",
                ipRange: "172.28.5.0/24",
                gateway: "172.28.5.1",
                auxAddresses: [
                    "host1": "172.28.1.5",
                    "host2": "172.28.1.6"
                ]
            ),
            ComposeNetworkIPAMConfig(
                subnet: "172.29.0.0/16",
                gateway: "172.29.0.1"
            )
        ])
        XCTAssertTrue(project.diagnostics.isEmpty)
    }

    func testMergesTopLevelNetworkLabelsAsSequencesAcrossOrderedComposeFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: nginx
            networks:
              - front
        networks:
          front:
            labels:
              com.example.role: edge
              com.example.shared: base
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        networks:
          front:
            labels:
              - com.example.shared=override
              - com.example.tier=public
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: [basePath.path, overridePath.path])

        XCTAssertEqual(project.networks["front"]?.labels, [
            "com.example.role=edge",
            "com.example.shared=base",
            "com.example.shared=override",
            "com.example.tier=public"
        ])
        XCTAssertTrue(project.diagnostics.isEmpty)
    }

    func testInvalidTopLevelNetworkOptionsProduceDiagnostics() throws {
        let yaml = """
        services:
          web:
            image: nginx
        networks:
          front:
            attachable: sometimes
            driver_opts: invalid
            ipam:
              config:
                - subnet: 172.28.0.0/16
                  unknown: true
                - invalid
              unknown: true
            unknown: true
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "networks.front.attachable"
            && $0.message == "Expected a boolean value."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "networks.front.driver_opts"
            && $0.message == "Expected a string mapping."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "networks.front.ipam.unknown"
            && $0.message == "Network ipam field is not implemented yet."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "networks.front.ipam.config[0].unknown"
            && $0.message == "Network ipam config field is not implemented yet."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "networks.front.ipam.config[1]"
            && $0.message == "Expected a mapping for network ipam config."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "networks.front.unknown"
            && $0.message == "Network field is not implemented yet."
        })
    }

    func testLoadsTopLevelVolumeOptions() throws {
        let yaml = """
        services:
          web:
            image: nginx
            volumes:
              - data:/data
        volumes:
          data:
            name: shared_data
            driver: local
            driver_opts:
              type: nfs
              o: addr=10.40.0.199,nolock,soft,rw
              device: :/docker/example
            labels:
              com.example.scope: dev
            x-volume-note: ignored
          external-data:
            external:
              name: existing_data
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let data = try XCTUnwrap(project.volumes["data"])
        let external = try XCTUnwrap(project.volumes["external-data"])

        XCTAssertEqual(data.customName, "shared_data")
        XCTAssertEqual(data.driver, "local")
        XCTAssertEqual(data.driverOptions, [
            "device": ":/docker/example",
            "o": "addr=10.40.0.199,nolock,soft,rw",
            "type": "nfs"
        ])
        XCTAssertEqual(data.labels, ["com.example.scope=dev"])
        XCTAssertTrue(data.hasUnmappedOptions)
        XCTAssertEqual(external.external, true)
        XCTAssertEqual(external.externalName, "existing_data")
        XCTAssertFalse(project.diagnostics.contains { $0.path.contains("x-volume-note") })
    }

    func testMergesTopLevelVolumeLabelsAsSequencesAcrossOrderedComposeFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: nginx
            volumes:
              - data:/data
        volumes:
          data:
            labels:
              com.example.scope: base
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        volumes:
          data:
            labels:
              - com.example.scope=override
              - com.example.owner=storage
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: [basePath.path, overridePath.path])

        XCTAssertEqual(project.volumes["data"]?.labels, [
            "com.example.scope=base",
            "com.example.scope=override",
            "com.example.owner=storage"
        ])
        XCTAssertTrue(project.diagnostics.isEmpty)
    }

    func testInvalidTopLevelVolumeOptionsProduceDiagnostics() throws {
        let yaml = """
        services:
          web:
            image: nginx
        volumes:
          data:
            name: ""
            driver_opts: invalid
            unknown: true
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "volumes.data.name"
            && $0.message == "Expected a non-empty string."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "volumes.data.driver_opts"
            && $0.message == "Expected a string mapping."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "volumes.data.unknown"
            && $0.message == "Volume field is not implemented yet."
        })
    }

    func testLoadsTopLevelModelsAndServiceModelGrants() throws {
        let yaml = """
        name: demo
        services:
          api:
            image: example/api
            models:
              - embeddings
          worker:
            image: example/worker
            models:
              llm:
                endpoint_var: LLM_URL
                model_var: LLM_MODEL
        models:
          embeddings:
            model: ai/embedder
            endpoint: http://model-runner.local/embeddings
            context_size: 4096
          llm: ai/smollm2
        """

        let project = try ComposeLoader().load(yaml: yaml, sourcePath: "/tmp/demo/compose.yaml")

        XCTAssertEqual(project.models["embeddings"], ComposeModelDefinition(
            name: "embeddings",
            model: "ai/embedder",
            endpoint: "http://model-runner.local/embeddings",
            options: ["context_size": "4096"]
        ))
        XCTAssertEqual(project.models["llm"], ComposeModelDefinition(name: "llm", model: "ai/smollm2"))
        XCTAssertEqual(
            project.services.first { $0.name == "api" }?.modelGrants,
            [ComposeServiceModelGrant(name: "embeddings")]
        )
        XCTAssertEqual(
            project.services.first { $0.name == "worker" }?.modelGrants,
            [ComposeServiceModelGrant(name: "llm", endpointVariable: "LLM_URL", modelVariable: "LLM_MODEL")]
        )
        XCTAssertFalse(project.diagnostics.contains { $0.path == "models" || $0.path == "services.api.models" })
    }

    func testInvalidServiceModelsProducesDiagnostics() throws {
        let yaml = """
        services:
          api:
            image: example/api
            models: true
          worker:
            image: example/worker
            models:
              llm:
                endpoint_var: ""
                unknown:
                  nested: true
        models:
          llm:
            model: ai/smollm2
            metadata:
              nested: true
        """

        let project = try ComposeLoader().load(yaml: yaml, sourcePath: "/tmp/demo/compose.yaml")

        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.api.models" && $0.message == "Expected a list or mapping for models."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.worker.models.llm.endpoint_var" && $0.message == "Expected a non-empty string."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.worker.models.llm.unknown" && $0.message == "Model grant field is not implemented yet."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "models.llm.metadata" && $0.message == "Model definition field is not implemented yet."
        })
    }

    func testExtensionFieldsDoNotEmitUnsupportedDiagnostics() throws {
        let yaml = """
        x-shared:
          labels:
            com.example.shared: "true"
        name: demo
        services:
          web:
            image: nginx
            x-service-note: keep
            build:
              context: .
              x-build-cache-hint: local
            env_file:
              - path: .env
                x-env-note: optional
            develop:
              x-develop-note: true
              watch:
                - path: ./src
                  action: rebuild
                  x-watch-note: true
            models:
              llm:
                endpoint_var: LLM_URL
                x-grant-note: true
            gpus:
              - capabilities: ["gpu"]
                x-gpu-note: true
        models:
          llm:
            model: ai/smollm2
            context_size: 4096
            x-model-note: keep
            x-model-object:
              nested: true
        """

        let project = try ComposeLoader().load(yaml: yaml, sourcePath: "/tmp/demo/compose.yaml")
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(project.name, "demo")
        XCTAssertEqual(web.build?.context, ".")
        XCTAssertEqual(web.envFileEntries, [ComposeEnvFile(path: ".env")])
        XCTAssertEqual(web.develop?.watch, [ComposeDevelopWatchRule(path: "./src", action: "rebuild")])
        XCTAssertEqual(web.modelGrants, [ComposeServiceModelGrant(name: "llm", endpointVariable: "LLM_URL")])
        XCTAssertEqual(web.gpus, ComposeGPURequest(devices: [
            ComposeGPUDeviceRequest(capabilities: ["gpu"])
        ]))
        XCTAssertEqual(project.models["llm"]?.options, ["context_size": "4096"])
        XCTAssertFalse(project.diagnostics.contains { $0.path.contains("x-") })
    }

    func testNonExtensionUnknownFieldsStillWarn() throws {
        let yaml = """
        unknown_top:
          value: true
        services:
          web:
            image: nginx
            unknown_service: true
            build:
              context: .
              unknown_build: true
        """

        let project = try ComposeLoader().load(yaml: yaml, sourcePath: "/tmp/demo/compose.yaml")

        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "unknown_top" && $0.message == "Top-level field is not implemented yet."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.web.unknown_service" && $0.message == "Service field is not implemented yet."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.web.build.unknown_build" && $0.message == "Build option is not implemented yet."
        })
    }

    func testLoadsServiceDevelopWatchRules() throws {
        let yaml = """
        services:
          frontend:
            image: example/webapp
            develop:
              watch:
                - path: ./webapp/html
                  action: sync
                  initial_sync: true
                  target: /var/www
                  ignore:
                    - node_modules/
                  include: "*.html"
                - path: ./etc/config
                  action: sync+exec
                  target: /etc/config/
                  exec:
                    command: app reload
                    user: app
                    privileged: false
                    working_dir: /srv/app
                    environment:
                      RELOAD: "1"
        """

        let project = try ComposeLoader().load(yaml: yaml, sourcePath: "/tmp/demo/compose.yaml")
        let develop = try XCTUnwrap(project.services.first { $0.name == "frontend" }?.develop)

        XCTAssertEqual(develop.watch, [
            ComposeDevelopWatchRule(
                path: "./webapp/html",
                action: "sync",
                target: "/var/www",
                ignore: ["node_modules/"],
                include: ["*.html"],
                initialSync: true
            ),
            ComposeDevelopWatchRule(
                path: "./etc/config",
                action: "sync+exec",
                target: "/etc/config/",
                exec: ComposeDevelopExec(
                    command: ["app reload"],
                    user: "app",
                    privileged: false,
                    workingDirectory: "/srv/app",
                    environment: ["RELOAD": "1"]
                )
            )
        ])
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.frontend.develop" })
    }

    func testInvalidServiceDevelopProducesDiagnostics() throws {
        let yaml = """
        services:
          frontend:
            image: example/webapp
            develop:
              watch:
                - action: sync
                - path: ./etc/config
                  action: sync+exec
                  exec:
                    user: app
                - path: ./src
                  action: rebuild
                  unknown: true
        """

        let project = try ComposeLoader().load(yaml: yaml, sourcePath: "/tmp/demo/compose.yaml")
        let develop = try XCTUnwrap(project.services.first { $0.name == "frontend" }?.develop)

        XCTAssertEqual(develop.watch.map(\.path), ["./etc/config", "./src"])
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.frontend.develop.watch[0]" && $0.message == "Develop watch rule was ignored."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.frontend.develop.watch[1].exec.command"
            && $0.message == "Develop exec command is required for sync+exec."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.frontend.develop.watch[2].unknown"
            && $0.message == "Develop watch field is not implemented yet."
        })
    }

    func testLoadsServiceDeployMetadata() throws {
        let yaml = """
        services:
          api:
            image: example/api
            deploy:
              x-deploy-note: ignored
              endpoint_mode: vip
              labels:
                com.example.tier: frontend
              mode: replicated
              replicas: 3
              placement:
                x-placement-note: ignored
                constraints:
                  - node.labels.zone == east
                preferences:
                  - spread: node.labels.zone
              resources:
                x-resources-note: ignored
                limits:
                  x-limits-note: ignored
                  cpus: "0.50"
                  memory: 512M
                  pids: 100
                reservations:
                  cpus: "0.25"
                  memory: 128M
                  devices:
                    - capabilities: ["gpu"]
                      driver: nvidia
                      count: 1
                      x-device-note: ignored
                      options:
                        virtualization: false
              restart_policy:
                x-restart-note: ignored
                condition: on-failure
                delay: 5s
                max_attempts: 3
                window: 120s
              update_config:
                x-update-note: ignored
                parallelism: 2
                delay: 10s
                failure_action: rollback
                monitor: 60s
                max_failure_ratio: 0.3
                order: start-first
              rollback_config:
                x-rollback-note: ignored
                parallelism: 1
                order: stop-first
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let service = try XCTUnwrap(project.services.first)

        XCTAssertEqual(service.deploy, ComposeDeploy(
            endpointMode: "vip",
            labels: ["com.example.tier=frontend"],
            mode: "replicated",
            replicas: 3,
            placement: ComposeDeployPlacement(
                constraints: ["node.labels.zone == east"],
                preferences: [["spread": "node.labels.zone"]]
            ),
            resources: ComposeDeployResources(
                limits: ComposeDeployResourceSpec(cpus: "0.50", memory: "512M", pids: 100),
                reservations: ComposeDeployResourceSpec(
                    cpus: "0.25",
                    memory: "128M",
                    devices: [
                        ComposeDeployDeviceReservation(
                            capabilities: ["gpu"],
                            driver: "nvidia",
                            count: "1",
                            options: ["virtualization": "false"]
                        )
                    ]
                )
            ),
            restartPolicy: ComposeDeployRestartPolicy(
                condition: "on-failure",
                delay: "5s",
                maxAttempts: 3,
                window: "120s"
            ),
            rollbackConfig: ComposeDeployUpdateConfig(parallelism: 1, order: "stop-first"),
            updateConfig: ComposeDeployUpdateConfig(
                parallelism: 2,
                delay: "10s",
                failureAction: "rollback",
                monitor: "60s",
                maxFailureRatio: "0.3",
                order: "start-first"
            )
        ))
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.api.deploy" })
        XCTAssertFalse(project.diagnostics.contains { $0.path.contains("x-") })
    }

    func testMergesServiceDeployPlacementConstraintsDeduplicatesAcrossOrderedComposeFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          api:
            image: example/api
            deploy:
              placement:
                constraints:
                  - node.labels.zone == east
                  - node.role == worker
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          api:
            deploy:
              placement:
                constraints:
                  - node.role == worker
                  - node.labels.disk == ssd
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: [basePath.path, overridePath.path])

        XCTAssertEqual(project.services.first?.deploy?.placement?.constraints, [
            "node.labels.zone == east",
            "node.role == worker",
            "node.labels.disk == ssd"
        ])
        XCTAssertTrue(project.diagnostics.isEmpty)
    }

    func testMergesServiceDeployPlacementPreferencesDeduplicatesExactEntriesAcrossOrderedComposeFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          api:
            image: example/api
            deploy:
              placement:
                preferences:
                  - spread: node.labels.zone
                  - spread: node.labels.rack
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          api:
            deploy:
              placement:
                preferences:
                  - spread: node.labels.zone
                  - spread: node.labels.disk
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: [basePath.path, overridePath.path])

        XCTAssertEqual(project.services.first?.deploy?.placement?.preferences, [
            ["spread": "node.labels.zone"],
            ["spread": "node.labels.rack"],
            ["spread": "node.labels.disk"]
        ])
        XCTAssertTrue(project.diagnostics.isEmpty)
    }

    func testMergesServiceDeployPlacementPreferencesKeepsDistinctEntriesAcrossOrderedComposeFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          api:
            image: example/api
            deploy:
              placement:
                preferences:
                  - spread: node.labels.zone
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          api:
            deploy:
              placement:
                preferences:
                  - spread: node.labels.rack
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: [basePath.path, overridePath.path])

        XCTAssertEqual(project.services.first?.deploy?.placement?.preferences, [
            ["spread": "node.labels.zone"],
            ["spread": "node.labels.rack"]
        ])
        XCTAssertTrue(project.diagnostics.isEmpty)
    }

    func testLoadsServiceDeployReservationsGenericResources() throws {
        let yaml = """
        services:
          api:
            image: example/api
            deploy:
              resources:
                reservations:
                  generic_resources:
                    - discrete_resource_spec:
                        kind: gpu
                        value: 2
                    - named_resource_spec:
                        kind: fpga
                        value: board-1
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let reservations = try XCTUnwrap(project.services.first?.deploy?.resources?.reservations)

        XCTAssertEqual(reservations.genericResources, [
            ComposeDeployGenericResource(
                discreteResourceSpec: ComposeDeployGenericResourceSpec(kind: "gpu", value: "2")
            ),
            ComposeDeployGenericResource(
                namedResourceSpec: ComposeDeployGenericResourceSpec(kind: "fpga", value: "board-1")
            )
        ])
        XCTAssertFalse(project.diagnostics.contains { $0.path.contains("generic_resources") })
    }

    func testMergesServiceDeployReservationsGenericResourcesDeduplicatesAcrossOrderedComposeFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          api:
            image: example/api
            deploy:
              resources:
                reservations:
                  generic_resources:
                    - discrete_resource_spec:
                        kind: gpu
                        value: 2
                    - named_resource_spec:
                        kind: fpga
                        value: board-1
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          api:
            deploy:
              resources:
                reservations:
                  generic_resources:
                    - discrete_resource_spec:
                        kind: gpu
                        value: 2
                    - named_resource_spec:
                        kind: gpu
                        value: gpu-1
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: [basePath.path, overridePath.path])
        let reservations = try XCTUnwrap(project.services.first?.deploy?.resources?.reservations)

        XCTAssertEqual(reservations.genericResources, [
            ComposeDeployGenericResource(
                discreteResourceSpec: ComposeDeployGenericResourceSpec(kind: "gpu", value: "2")
            ),
            ComposeDeployGenericResource(
                namedResourceSpec: ComposeDeployGenericResourceSpec(kind: "fpga", value: "board-1")
            ),
            ComposeDeployGenericResource(
                namedResourceSpec: ComposeDeployGenericResourceSpec(kind: "gpu", value: "gpu-1")
            )
        ])
        XCTAssertTrue(project.diagnostics.isEmpty)
    }

    func testInvalidServiceDeployProducesDiagnostics() throws {
        let yaml = """
        services:
          api:
            image: example/api
            deploy:
              unknown: true
              placement:
                unknown: true
              resources:
                unsupported: true
                reservations:
                  devices:
                    - driver: nvidia
                      count: 1
                      device_ids: ["GPU-1"]
                      unknown: true
              restart_policy:
                unknown: true
              update_config:
                unknown: true
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let deploy = try XCTUnwrap(project.services.first?.deploy)

        XCTAssertEqual(deploy.resources?.reservations?.devices, [
            ComposeDeployDeviceReservation(driver: "nvidia", count: "1", deviceIDs: ["GPU-1"])
        ])
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.api.deploy.unknown" && $0.message == "Deploy field is not implemented yet."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.api.deploy.placement.unknown" && $0.message == "Deploy placement field is not implemented yet."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.api.deploy.resources.unsupported" && $0.message == "Deploy resources field is not implemented yet."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.api.deploy.resources.reservations.devices[0].unknown"
            && $0.message == "Deploy device reservation field is not implemented yet."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.api.deploy.resources.reservations.devices[0].capabilities"
            && $0.message == "Deploy device reservation capabilities are required."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.api.deploy.resources.reservations.devices[0]"
            && $0.message == "Deploy device reservation count and device_ids are mutually exclusive."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.api.deploy.restart_policy.unknown"
            && $0.message == "Deploy restart_policy field is not implemented yet."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.api.deploy.update_config.unknown"
            && $0.message == "Deploy update config field is not implemented yet."
        })
    }

    func testLoadsServiceEnvFileLongSyntax() throws {
        let yaml = """
        services:
          web:
            image: nginx
            env_file:
              - .env
              - path: optional.env
                required: false
              - path: raw.env
                format: raw
        """

        let project = try ComposeLoader().load(yaml: yaml, sourcePath: "/tmp/demo/compose.yaml")
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.envFiles, [".env", "optional.env", "raw.env"])
        XCTAssertEqual(web.envFileEntries, [
            ComposeEnvFile(path: ".env"),
            ComposeEnvFile(path: "optional.env", required: false),
            ComposeEnvFile(path: "raw.env", format: "raw")
        ])
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.env_file" })
    }

    func testInvalidServiceEnvFileLongSyntaxProducesDiagnostics() throws {
        let yaml = """
        services:
          web:
            image: nginx
            env_file:
              - path: ""
                required: maybe
                unknown: true
              - enabled: true
        """

        let project = try ComposeLoader().load(yaml: yaml, sourcePath: "/tmp/demo/compose.yaml")
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertTrue(web.envFileEntries.isEmpty)
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.web.env_file[0].path" && $0.message == "Expected a non-empty string."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.web.env_file[0].required" && $0.message == "Expected a boolean value."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.web.env_file[0].unknown" && $0.message == "env_file field is not implemented yet."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.web.env_file[1]" && $0.message == "env_file item was ignored."
        })
    }

    func testDefaultComposeDiscoveryWalksParentDirectoriesAndLoadsSiblingOverride() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }
        let nested = workdir.appendingPathComponent("apps/web")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        try """
        name: parent-demo
        services:
          web:
            image: nginx:alpine
            environment:
              LOG_LEVEL: info
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try """
        services:
          web:
            environment:
              LOG_LEVEL: debug
          worker:
            image: alpine
        """.write(to: workdir.appendingPathComponent("compose.override.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: nested.path)

        XCTAssertEqual(project.sourcePath, workdir.appendingPathComponent("compose.yaml").path)
        XCTAssertEqual(project.name, "parent-demo")
        XCTAssertEqual(project.services.map(\.name), ["web", "worker"])
        XCTAssertEqual(project.services.first { $0.name == "web" }?.environment["LOG_LEVEL"], "debug")
    }

    func testDefaultComposeDiscoveryPrefersNearestDirectoryBeforeParent() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }
        let nested = workdir.appendingPathComponent("apps/web")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        try """
        services:
          parent:
            image: busybox
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try """
        services:
          child:
            image: nginx:alpine
        """.write(to: nested.appendingPathComponent("docker-compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: nested.path)

        XCTAssertEqual(project.sourcePath, nested.appendingPathComponent("docker-compose.yaml").path)
        XCTAssertEqual(project.services.map(\.name), ["child"])
    }

    func testExplicitComposeFileDoesNotTraverseToParentDirectories() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }
        let nested = workdir.appendingPathComponent("apps/web")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        try """
        services:
          parent:
            image: busybox
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ComposeLoader().load(
            from: ["compose.yaml"],
            workingDirectory: nested.path
        )) { error in
            guard case ComposeLoadError.fileNotFound(let candidates) = error else {
                return XCTFail("Expected explicit nested path lookup failure, got \(error).")
            }
            XCTAssertEqual(candidates, [nested.appendingPathComponent("compose.yaml").path])
        }
    }

    func testExplicitComposeFileDoesNotLoadDefaultOverride() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx:alpine
            environment:
              LOG_LEVEL: info
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try """
        services:
          web:
            environment:
              LOG_LEVEL: debug
        """.write(to: workdir.appendingPathComponent("compose.override.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(
            from: [workdir.appendingPathComponent("compose.yaml").path]
        )

        XCTAssertEqual(project.services.first?.environment["LOG_LEVEL"], "info")
    }

    func testOrderedComposeSourcesCanMergeInMemoryYAMLWithFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        name: mixed-demo
        services:
          web:
            image: nginx:alpine
            environment:
              LOG_LEVEL: info
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try """
        services:
          web:
            environment:
              LOG_LEVEL: debug
          worker:
            image: alpine
        """.write(to: workdir.appendingPathComponent("override.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(
            from: [
                ComposeSource(path: "compose.yaml"),
                ComposeSource(path: "stdin-compose.yaml", yaml: """
                services:
                  web:
                    ports:
                      - "8080:80"
                """),
                ComposeSource(path: "override.yaml")
            ],
            workingDirectory: workdir.path
        )

        let web = try XCTUnwrap(project.services.first { $0.name == "web" })
        XCTAssertEqual(project.sourcePath, workdir.appendingPathComponent("compose.yaml").path)
        XCTAssertEqual(project.services.map(\.name), ["web", "worker"])
        XCTAssertEqual(web.environment["LOG_LEVEL"], "debug")
        XCTAssertEqual(web.ports, ["8080:80"])
    }

    func testLoadsTopLevelConfigsAndSecretsAndServiceGrants() throws {
        let yaml = """
        name: demo
        services:
          web:
            image: nginx
            configs:
              - app-config
              - source: nginx-conf
                target: /etc/nginx/conf.d/default.conf
                mode: "0444"
            secrets:
              - db-password
              - source: api-token
                target: token
                uid: "1000"
                gid: "1000"
        configs:
          app-config:
            file: ./config/app.yml
          nginx-conf:
            content: |
              server {}
        secrets:
          db-password:
            file: ./secrets/db-password
          api-token:
            environment: API_TOKEN
        """

        let project = try ComposeLoader().load(yaml: yaml, sourcePath: "/tmp/demo/compose.yaml")
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(project.configs["app-config"]?.file, "./config/app.yml")
        XCTAssertEqual(project.configs["nginx-conf"]?.content, "server {}\n")
        XCTAssertEqual(project.secrets["db-password"]?.file, "./secrets/db-password")
        XCTAssertEqual(project.secrets["api-token"]?.environment, "API_TOKEN")
        XCTAssertEqual(web.configs, [
            ComposeServiceResourceGrant(source: "app-config", target: "/app-config"),
            ComposeServiceResourceGrant(source: "nginx-conf", target: "/etc/nginx/conf.d/default.conf", mode: "0444")
        ])
        XCTAssertEqual(web.secrets, [
            ComposeServiceResourceGrant(source: "db-password", target: "/run/secrets/db-password"),
            ComposeServiceResourceGrant(source: "api-token", target: "/run/secrets/token", uid: "1000", gid: "1000")
        ])
        XCTAssertFalse(project.diagnostics.contains { $0.path == "configs" || $0.path == "secrets" })
    }

    func testLoadsServiceLabelsFromMapAndListSyntax() throws {
        let yaml = """
        services:
          api:
            image: backend
            labels:
              com.example.role: api
              com.example.empty: ""
          web:
            image: nginx
            labels:
              - com.example.description=Public web
              - com.example.flag
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let api = try XCTUnwrap(project.services.first { $0.name == "api" })
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(api.labels, ["com.example.empty=", "com.example.role=api"])
        XCTAssertEqual(web.labels, ["com.example.description=Public web", "com.example.flag"])
        XCTAssertFalse(project.diagnostics.contains { $0.path.contains(".labels") })
    }

    func testLoadsServiceAnnotationsFromMapAndListSyntax() throws {
        let yaml = """
        services:
          api:
            image: backend
            annotations:
              com.example.role: api
              com.example.empty: ""
          web:
            image: nginx
            annotations:
              - com.example.description=Public web
              - com.example.flag
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let api = try XCTUnwrap(project.services.first { $0.name == "api" })
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(api.annotations, ["com.example.empty=", "com.example.role=api"])
        XCTAssertEqual(web.annotations, ["com.example.description=Public web", "com.example.flag"])
        XCTAssertFalse(project.diagnostics.contains { $0.path.contains(".annotations") })
    }

    func testLoadsServiceAttach() throws {
        let yaml = """
        services:
          web:
            image: nginx
            attach: false
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.attach, false)
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.attach" })
    }

    func testInvalidServiceAttachProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            attach: maybe
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.attach)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.attach"
            && $0.message == "Expected a boolean value."
        })
    }

    func testLoadsServiceBlockIOConfig() throws {
        let yaml = """
        services:
          web:
            image: nginx
            blkio_config:
              weight: 300
              weight_device:
                - path: /dev/sda
                  weight: 400
              device_read_bps:
                - path: /dev/sdb
                  rate: 12mb
              device_read_iops:
                - path: /dev/sdc
                  rate: 120
              device_write_bps:
                - path: /dev/sdd
                  rate: 1024k
              device_write_iops:
                - path: /dev/sde
                  rate: 30
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let blockIOConfig = try XCTUnwrap(project.services.first?.blockIOConfig)

        XCTAssertEqual(blockIOConfig.weight, 300)
        XCTAssertEqual(blockIOConfig.weightDevice, [
            ComposeBlockIODeviceWeight(path: "/dev/sda", weight: 400)
        ])
        XCTAssertEqual(blockIOConfig.deviceReadBps, [
            ComposeBlockIODeviceRate(path: "/dev/sdb", rate: "12mb")
        ])
        XCTAssertEqual(blockIOConfig.deviceReadIOps, [
            ComposeBlockIODeviceRate(path: "/dev/sdc", rate: "120")
        ])
        XCTAssertEqual(blockIOConfig.deviceWriteBps, [
            ComposeBlockIODeviceRate(path: "/dev/sdd", rate: "1024k")
        ])
        XCTAssertEqual(blockIOConfig.deviceWriteIOps, [
            ComposeBlockIODeviceRate(path: "/dev/sde", rate: "30")
        ])
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.blkio_config" })
    }

    func testMergesBlkioConfigDeviceRatesByPathAcrossOrderedComposeFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: nginx
            blkio_config:
              device_read_bps:
                - path: /dev/sdb
                  rate: 12mb
                - path: /dev/sdc
                  rate: 20mb
              device_write_iops:
                - path: /dev/sde
                  rate: 30
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          web:
            blkio_config:
              device_read_bps:
                - path: /dev/sdb
                  rate: 30mb
                - path: /dev/sdd
                  rate: 40mb
              device_write_iops:
                - path: /dev/sde
                  rate: 60
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(
            from: [basePath.path, overridePath.path],
            activeProfiles: []
        )
        let blockIOConfig = try XCTUnwrap(project.services.first?.blockIOConfig)

        XCTAssertEqual(blockIOConfig.deviceReadBps, [
            ComposeBlockIODeviceRate(path: "/dev/sdb", rate: "30mb"),
            ComposeBlockIODeviceRate(path: "/dev/sdc", rate: "20mb"),
            ComposeBlockIODeviceRate(path: "/dev/sdd", rate: "40mb")
        ])
        XCTAssertEqual(blockIOConfig.deviceWriteIOps, [
            ComposeBlockIODeviceRate(path: "/dev/sde", rate: "60")
        ])
    }

    func testMergesBlkioConfigWeightDevicesByPathAcrossOrderedComposeFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: nginx
            blkio_config:
              weight_device:
                - path: /dev/sda
                  weight: 400
                - path: /dev/sdb
                  weight: 500
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          web:
            blkio_config:
              weight_device:
                - path: /dev/sda
                  weight: 600
                - path: /dev/sdc
                  weight: 700
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(
            from: [basePath.path, overridePath.path],
            activeProfiles: []
        )
        let blockIOConfig = try XCTUnwrap(project.services.first?.blockIOConfig)

        XCTAssertEqual(blockIOConfig.weightDevice, [
            ComposeBlockIODeviceWeight(path: "/dev/sda", weight: 600),
            ComposeBlockIODeviceWeight(path: "/dev/sdb", weight: 500),
            ComposeBlockIODeviceWeight(path: "/dev/sdc", weight: 700)
        ])
    }

    func testInvalidServiceBlockIOConfigProducesDiagnostics() throws {
        let yaml = """
        services:
          web:
            image: nginx
            blkio_config:
              weight: 2
              weight_device:
                - path: /dev/sda
                  weight: 5000
                - not-a-map
              device_read_bps:
                - path: /dev/sdb
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let blockIOConfig = try XCTUnwrap(project.services.first?.blockIOConfig)

        XCTAssertNil(blockIOConfig.weight)
        XCTAssertEqual(blockIOConfig.weightDevice, [])
        XCTAssertEqual(blockIOConfig.deviceReadBps, [])
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.blkio_config.weight"
            && $0.message == "blkio_config weight must be within the [10, 1000] range."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.blkio_config.weight_device[0].weight"
            && $0.message == "blkio_config weight must be within the [10, 1000] range."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.blkio_config.weight_device[1]"
            && $0.message == "Expected a blkio_config device weight mapping."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.blkio_config.device_read_bps[0].rate"
            && $0.message == "Expected a non-empty string."
        })
    }

    func testBlockIOConfigDecodesPartialJSONWithDefaults() throws {
        let json = #"{"weight":300}"#.data(using: .utf8)!

        let blockIOConfig = try JSONDecoder().decode(ComposeBlockIOConfig.self, from: json)

        XCTAssertEqual(blockIOConfig.weight, 300)
        XCTAssertEqual(blockIOConfig.weightDevice, [])
        XCTAssertEqual(blockIOConfig.deviceReadBps, [])
        XCTAssertEqual(blockIOConfig.deviceReadIOps, [])
        XCTAssertEqual(blockIOConfig.deviceWriteBps, [])
        XCTAssertEqual(blockIOConfig.deviceWriteIOps, [])
    }

    func testLoadsServiceCPUSchedulerFields() throws {
        let yaml = """
        services:
          web:
            image: nginx
            cpu_count: 4
            cpu_percent: 80
            cpu_shares: 1024
            cpu_period: 100000
            cpu_quota: 50000
            cpu_rt_runtime: 400ms
            cpu_rt_period: 1400us
            cpuset: "0-3"
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let service = try XCTUnwrap(project.services.first)

        XCTAssertEqual(service.cpuCount, 4)
        XCTAssertEqual(service.cpuPercent, 80)
        XCTAssertEqual(service.cpuShares, 1024)
        XCTAssertEqual(service.cpuPeriod, 100_000)
        XCTAssertEqual(service.cpuQuota, 50_000)
        XCTAssertEqual(service.cpuRTRuntime, "400ms")
        XCTAssertEqual(service.cpuRTPeriod, "1400us")
        XCTAssertEqual(service.cpuSet, "0-3")
        XCTAssertFalse(project.diagnostics.contains { $0.path.contains("cpu_") || $0.path == "services.web.cpuset" })
    }

    func testInvalidServiceCPUSchedulerFieldsProduceDiagnostics() throws {
        let yaml = """
        services:
          web:
            image: nginx
            cpu_count: many
            cpu_percent: eighty
            cpu_shares: high
            cpu_period: soon
            cpu_quota: lots
            cpu_rt_runtime: []
            cpu_rt_period: {}
            cpuset: []
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let service = try XCTUnwrap(project.services.first)

        XCTAssertNil(service.cpuCount)
        XCTAssertNil(service.cpuPercent)
        XCTAssertNil(service.cpuShares)
        XCTAssertNil(service.cpuPeriod)
        XCTAssertNil(service.cpuQuota)
        XCTAssertNil(service.cpuRTRuntime)
        XCTAssertNil(service.cpuRTPeriod)
        XCTAssertNil(service.cpuSet)
        for path in [
            "services.web.cpu_count",
            "services.web.cpu_percent",
            "services.web.cpu_shares",
            "services.web.cpu_period",
            "services.web.cpu_quota"
        ] {
            XCTAssertTrue(project.diagnostics.contains {
                $0.severity == .warning
                && $0.path == path
                && $0.message == "Expected an integer value."
            }, "Missing diagnostic for \(path)")
        }
        for path in [
            "services.web.cpu_rt_runtime",
            "services.web.cpu_rt_period",
            "services.web.cpuset"
        ] {
            XCTAssertTrue(project.diagnostics.contains {
                $0.severity == .error
                && $0.path == path
                && $0.message == "Expected a non-empty string."
            }, "Missing diagnostic for \(path)")
        }
    }

    func testLoadsServiceLabelsFromLabelFilesWithInlineOverride() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        com.example.role=base
        com.example.keep=from-base
        """.write(to: workdir.appendingPathComponent("base.labels"), atomically: true, encoding: .utf8)
        try """
        com.example.role=override-file
        com.example.extra=from-extra
        """.write(to: workdir.appendingPathComponent("extra.labels"), atomically: true, encoding: .utf8)
        try """
        services:
          web:
            image: nginx
            label_file:
              - base.labels
              - extra.labels
            labels:
              com.example.role: inline
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.labelFiles, ["base.labels", "extra.labels"])
        XCTAssertEqual(web.labels, [
            "com.example.keep=from-base",
            "com.example.extra=from-extra",
            "com.example.role=inline"
        ])
        XCTAssertFalse(project.diagnostics.contains { $0.path.contains("label_file") })
    }

    func testMissingServiceLabelFileProducesDiagnostic() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
            label_file: missing.labels
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.labelFiles, ["missing.labels"])
        XCTAssertEqual(web.labels, [])
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.label_file[0]"
            && $0.message == "Label file does not exist: missing.labels"
        })
    }

    func testLoadsBuildStringSyntax() throws {
        let yaml = """
        services:
          web:
            build: ./web
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.build, ComposeBuild(context: "./web"))
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.build" })
    }

    func testLoadsSameFileServiceExtendsWithComposeMergeRules() throws {
        let yaml = """
        services:
          base:
            image: example/base
            command: ["bundle", "exec"]
            environment:
              LOG_LEVEL: info
              SHARED: base
            labels:
              com.example.role: base
              com.example.shared: base
            ports:
              - "8080:80"
            volumes:
              - base-cache:/var/cache/app:rw
            depends_on:
              - db
            profiles:
              - debug
            cap_add:
              - NET_ADMIN
              - CHOWN
            cap_drop:
              - MKNOD
            device_cgroup_rules:
              - c 1:3 mr
            external_links:
              - redis
            devices:
              - "/dev/base:/dev/shared:rwm"
              - "vendor1.com/device=gpu"
          web:
            extends:
              service: base
            command: ["./run-web"]
            environment:
              SHARED: web
              WEB_ONLY: "1"
            labels:
              com.example.role: web
            ports:
              - "9090:90"
            volumes:
              - web-cache:/var/cache/app:ro
            depends_on:
              - redis
            profiles:
              - web
            cap_add:
              - NET_ADMIN
              - SYS_PTRACE
            cap_drop:
              - MKNOD
              - NET_RAW
            device_cgroup_rules:
              - c 1:3 mr
              - a 7:* rmw
            external_links:
              - redis
              - database:mysql
            devices:
              - "/dev/web:/dev/shared:rw"
              - "/dev/web-only:/dev/web-only"
              - "vendor1.com/device=gpu"
          db:
            image: postgres
          redis:
            image: redis
        volumes:
          base-cache: {}
          web-cache: {}
        """

        let project = try ComposeLoader().load(yaml: yaml, activeProfiles: ["debug", "web"])
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.image, "example/base")
        XCTAssertEqual(web.command, ["./run-web"])
        XCTAssertEqual(web.environment, [
            "LOG_LEVEL": "info",
            "SHARED": "web",
            "WEB_ONLY": "1"
        ])
        XCTAssertEqual(web.labels, [
            "com.example.role=web",
            "com.example.shared=base"
        ])
        XCTAssertEqual(web.ports, ["8080:80", "9090:90"])
        XCTAssertEqual(web.volumes, ["web-cache:/var/cache/app:ro"])
        XCTAssertEqual(web.dependsOn, ["db", "redis"])
        XCTAssertEqual(web.profiles, ["debug", "web"])
        XCTAssertEqual(web.capAdd, ["NET_ADMIN", "CHOWN", "SYS_PTRACE"])
        XCTAssertEqual(web.capDrop, ["MKNOD", "NET_RAW"])
        XCTAssertEqual(web.deviceCgroupRules, ["c 1:3 mr", "a 7:* rmw"])
        XCTAssertEqual(web.externalLinks, ["redis", "database:mysql"])
        XCTAssertEqual(web.devices, [
            "/dev/web:/dev/shared:rw",
            "vendor1.com/device=gpu",
            "/dev/web-only:/dev/web-only"
        ])
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.extends" })
    }

    func testServiceExtendsRejectsNewHealthcheckDisable() throws {
        let yaml = """
        services:
          base:
            image: busybox
            healthcheck:
              test: ["CMD", "true"]
          web:
            extends:
              service: base
            healthcheck:
              disable: true
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.healthcheck?.disabled, true)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.healthcheck.disable"
            && $0.message.contains("cannot newly disable healthchecks")
        })
    }

    func testServiceExtendsAllowsHealthcheckDisableWhenBaseDisablesIt() throws {
        let yaml = """
        services:
          base:
            image: busybox
            healthcheck:
              disable: true
          web:
            extends:
              service: base
            healthcheck:
              disable: true
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.healthcheck?.disabled, true)
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.healthcheck.disable" })
    }

    func testServiceExtendsAllowsHealthcheckDisableWhenBaseUsesNoneTest() throws {
        let yaml = """
        services:
          base:
            image: busybox
            healthcheck:
              test: ["NONE"]
          web:
            extends:
              service: base
            healthcheck:
              disable: true
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.healthcheck?.disabled, true)
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.healthcheck.disable" })
    }

    func testServiceExtendsRejectsNewHealthcheckNoneTest() throws {
        let yaml = """
        services:
          base:
            image: busybox
            healthcheck:
              test: ["CMD", "true"]
          web:
            extends:
              service: base
            healthcheck:
              test: ["NONE"]
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.healthcheck?.disabled, true)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.healthcheck.test"
            && $0.message.contains("cannot newly disable healthchecks")
        })
    }

    func testLoadsChainedSameFileServiceExtends() throws {
        let yaml = """
        services:
          base:
            image: busybox
            user: root
          common:
            extends:
              service: base
            environment:
              APP_ENV: base
          worker:
            extends: common
            command: ["./worker"]
            environment:
              WORKER: "1"
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let worker = try XCTUnwrap(project.services.first { $0.name == "worker" })

        XCTAssertEqual(worker.image, "busybox")
        XCTAssertEqual(worker.user, "root")
        XCTAssertEqual(worker.command, ["./worker"])
        XCTAssertEqual(worker.environment, [
            "APP_ENV": "base",
            "WORKER": "1"
        ])
    }

    func testFileBasedServiceExtendsLoadsReferencedServiceAndRewritesRelativePaths() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }
        try FileManager.default.createDirectory(
            at: workdir.appendingPathComponent("shared"),
            withIntermediateDirectories: true
        )

        try """
        services:
          app:
            image: example/app
            build:
              context: ./api
              dockerfile: Dockerfile
              additional_contexts:
                assets: assets
                remote: docker-image://example/assets:latest
            env_file:
              - env/defaults.env
              - path: env/optional.env
                required: false
            environment:
              LOG_LEVEL: info
              SHARED: base
            volumes:
              - config/shared:/etc/config:ro
              - type: bind
                source: logs
                target: /var/log/app
              - app-cache:/cache
        """.write(to: workdir.appendingPathComponent("shared/common.yaml"), atomically: true, encoding: .utf8)

        try """
        services:
          web:
            extends:
              file: shared/common.yaml
              service: app
            image: nginx
            environment:
              SHARED: web
              WEB_ONLY: "1"
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.image, "nginx")
        XCTAssertEqual(web.build?.context, "shared/api")
        XCTAssertEqual(web.build?.dockerfile, "Dockerfile")
        XCTAssertEqual(web.build?.additionalContexts, [
            "assets=shared/assets",
            "remote=docker-image://example/assets:latest"
        ])
        XCTAssertEqual(web.envFiles, ["shared/env/defaults.env", "shared/env/optional.env"])
        XCTAssertEqual(web.envFileEntries, [
            ComposeEnvFile(path: "shared/env/defaults.env"),
            ComposeEnvFile(path: "shared/env/optional.env", required: false)
        ])
        XCTAssertEqual(web.environment, [
            "LOG_LEVEL": "info",
            "SHARED": "web",
            "WEB_ONLY": "1"
        ])
        XCTAssertEqual(web.volumes, [
            "shared/config/shared:/etc/config:ro",
            "shared/logs:/var/log/app",
            "app-cache:/cache"
        ])
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.extends.file" })
    }

    func testFileBasedServiceExtendsMissingFileProducesDiagnosticAndKeepsLocalService() throws {
        let yaml = """
        services:
          web:
            extends:
              file: missing.yaml
              service: app
            image: nginx
        """

        let project = try ComposeLoader().load(yaml: yaml, sourcePath: "/tmp/demo/compose.yaml")
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.image, "nginx")
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.extends.file"
            && $0.message.contains("Extended Compose file could not be loaded")
        })
    }

    func testFileBasedServiceExtendsMissingServiceProducesDiagnosticAndKeepsLocalService() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          other:
            image: busybox
        """.write(to: workdir.appendingPathComponent("common.yaml"), atomically: true, encoding: .utf8)

        try """
        services:
          web:
            extends:
              file: common.yaml
              service: app
            image: nginx
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.image, "nginx")
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.extends.service"
            && $0.message.contains("Extended service 'app' is not defined")
            && $0.message.contains("common.yaml")
        })
    }

    func testFileBasedServiceExtendsUsesExplicitFileInsteadOfMergedService() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }
        try FileManager.default.createDirectory(
            at: workdir.appendingPathComponent("shared"),
            withIntermediateDirectories: true
        )

        try """
        services:
          base:
            image: example/shared
        """.write(to: workdir.appendingPathComponent("shared/compose.yaml"), atomically: true, encoding: .utf8)

        try """
        include:
          - shared/compose.yaml
        services:
          base:
            image: example/local
          web:
            extends:
              file: shared/compose.yaml
              service: base
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.image, "example/shared")
    }

    func testFileBasedServiceExtendsSetsDefaultBuildContextFromReferencedFileWhenOmitted() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }
        try FileManager.default.createDirectory(
            at: workdir.appendingPathComponent("shared"),
            withIntermediateDirectories: true
        )

        try """
        services:
          app:
            image: example/app
            build:
              dockerfile: Dockerfile.base
        """.write(to: workdir.appendingPathComponent("shared/common.yaml"), atomically: true, encoding: .utf8)

        try """
        services:
          web:
            extends:
              file: shared/common.yaml
              service: app
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.build?.context, "shared")
        XCTAssertEqual(web.build?.dockerfile, "Dockerfile.base")
    }

    func testFileBasedServiceExtendsDoesNotRewriteNamedVolumesAbsolutePathsOrSchemes() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }
        try FileManager.default.createDirectory(
            at: workdir.appendingPathComponent("shared"),
            withIntermediateDirectories: true
        )

        try """
        services:
          app:
            image: example/app
            build:
              context: /opt/app
              additional_contexts:
                - base=service:base
                - image=docker-image://example/app:latest
            env_file:
              - https://example.test/env/app.env
              - /opt/app/defaults.env
            volumes:
              - cache:/cache
              - /var/log/app:/var/log/app
              - type: volume
                source: other-cache
                target: /other-cache
              - type: bind
                source: /opt/app/config
                target: /config
        """.write(to: workdir.appendingPathComponent("shared/common.yaml"), atomically: true, encoding: .utf8)

        try """
        services:
          web:
            extends:
              file: shared/common.yaml
              service: app
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.build?.context, "/opt/app")
        XCTAssertEqual(web.build?.additionalContexts, [
            "base=service:base",
            "image=docker-image://example/app:latest"
        ])
        XCTAssertEqual(web.envFiles, [
            "https://example.test/env/app.env",
            "/opt/app/defaults.env"
        ])
        XCTAssertEqual(web.volumes, [
            "cache:/cache",
            "/var/log/app:/var/log/app",
            "other-cache:/other-cache",
            "/opt/app/config:/config"
        ])
    }

    func testFileBasedServiceExtendsDetectsCrossFileCycle() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          api:
            extends:
              file: b.yaml
              service: worker
            image: example/api
        """.write(to: workdir.appendingPathComponent("a.yaml"), atomically: true, encoding: .utf8)

        try """
        services:
          worker:
            extends:
              file: a.yaml
              service: api
            image: example/worker
        """.write(to: workdir.appendingPathComponent("b.yaml"), atomically: true, encoding: .utf8)

        try """
        services:
          web:
            extends:
              file: a.yaml
              service: api
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)

        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path.hasSuffix(".extends")
            && $0.message.contains("Circular service extends reference detected")
        })
    }

    func testMissingSameFileServiceExtendsEmitsDiagnosticAndKeepsLocalService() throws {
        let yaml = """
        services:
          web:
            extends:
              service: app
            image: nginx
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.image, "nginx")
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.extends.service"
            && $0.message.contains("Extended service 'app' is not defined")
        })
    }

    func testCircularSameFileServiceExtendsEmitsDiagnostic() throws {
        let yaml = """
        services:
          api:
            extends:
              service: worker
            image: example/api
          worker:
            extends:
              service: api
            image: example/worker
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path.hasSuffix(".extends")
            && $0.message.contains("Circular service extends reference detected")
        })
    }

    func testComposeProjectDecodesOlderJSONWithoutRemoteIncludes() throws {
        let json = """
        {
          "name": "demo",
          "services": [
            {
              "name": "web",
              "image": "nginx:alpine"
            }
          ],
          "sourcePath": "compose.yaml"
        }
        """

        let project = try JSONDecoder().decode(ComposeProject.self, from: Data(json.utf8))

        XCTAssertEqual(project.name, "demo")
        XCTAssertEqual(project.services.map(\.name), ["web"])
        XCTAssertEqual(project.remoteIncludes, [])
        XCTAssertEqual(project.diagnostics, [])
        XCTAssertEqual(project.services.first?.extraHosts, [])
    }

    func testComposeBuildDecodesOlderJSONWithoutNewBuildFields() throws {
        let json = """
        {
          "context": ".",
          "dockerfile": "Dockerfile.api",
          "args": ["GIT_COMMIT=abc123"],
          "labels": ["com.example.stage=dev"],
          "target": "runtime",
          "tags": ["example/api:latest"],
          "noCache": true,
          "pull": true,
          "platforms": ["linux/arm64"]
        }
        """

        let build = try JSONDecoder().decode(ComposeBuild.self, from: Data(json.utf8))

        XCTAssertEqual(build.context, ".")
        XCTAssertEqual(build.dockerfile, "Dockerfile.api")
        XCTAssertEqual(build.additionalContexts, [])
        XCTAssertNil(build.dockerfileInline)
        XCTAssertEqual(build.cacheFrom, [])
        XCTAssertEqual(build.cacheTo, [])
        XCTAssertEqual(build.entitlements, [])
        XCTAssertEqual(build.extraHosts, [])
        XCTAssertNil(build.isolation)
        XCTAssertNil(build.network)
        XCTAssertNil(build.privileged)
        XCTAssertEqual(build.secrets, [])
        XCTAssertNil(build.shmSize)
        XCTAssertEqual(build.ssh, [])
        XCTAssertNil(build.provenance)
        XCTAssertNil(build.sbom)
        XCTAssertEqual(build.ulimits, [])
    }

    func testLoadsBuildObjectSubset() throws {
        let yaml = """
        services:
          api:
            image: example/api:dev
            pull_policy: build
            platform: linux/arm64
            build:
              context: .
              dockerfile: Dockerfile.api
              args:
                GIT_COMMIT: abc123
                EMPTY:
              labels:
                com.example.stage: dev
              secrets:
                - npm-token
                - source: signing-key
                  target: cert
                  uid: "1000"
              target: runtime
              tags:
                - example/api:latest
              no_cache: true
              pull: true
              platforms:
                - linux/arm64
              additional_contexts:
                resources: ./resources
              cache_from:
                - example/cache
              cache_to:
                - type=local,dest=.build-cache
              dockerfile_inline: |
                FROM scratch
              entitlements:
                - network.host
              extra_hosts:
                db.local: 10.0.0.5
              isolation: default
              network: host
              privileged: true
              shm_size: 128m
              ssh:
                - default
              provenance: true
              sbom: generator=docker/scout-sbom-indexer:latest
              ulimits:
                nofile:
                  soft: 1024
                  hard: 2048
        secrets:
          npm-token:
            environment: NPM_TOKEN
          signing-key:
            file: ./signing.key
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let api = try XCTUnwrap(project.services.first { $0.name == "api" })

        XCTAssertEqual(api.pullPolicy, "build")
        XCTAssertEqual(api.build, ComposeBuild(
            context: ".",
            additionalContexts: ["resources=./resources"],
            dockerfile: "Dockerfile.api",
            dockerfileInline: "FROM scratch\n",
            args: ["EMPTY", "GIT_COMMIT=abc123"],
            cacheFrom: ["example/cache"],
            cacheTo: ["type=local,dest=.build-cache"],
            entitlements: ["network.host"],
            extraHosts: ["db.local=10.0.0.5"],
            isolation: "default",
            labels: ["com.example.stage=dev"],
            network: "host",
            privileged: true,
            secrets: [
                ComposeServiceResourceGrant(source: "npm-token", target: "/run/secrets/npm-token"),
                ComposeServiceResourceGrant(source: "signing-key", target: "/run/secrets/cert", uid: "1000")
            ],
            shmSize: "128m",
            ssh: ["default"],
            target: "runtime",
            tags: ["example/api:latest"],
            noCache: true,
            pull: true,
            platforms: ["linux/arm64"],
            provenance: "true",
            sbom: "generator=docker/scout-sbom-indexer:latest",
            ulimits: ["nofile=1024:2048"]
        ))
        XCTAssertEqual(project.secrets["npm-token"]?.environment, "NPM_TOKEN")
        XCTAssertEqual(project.secrets["signing-key"]?.file, "./signing.key")
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.api.pull_policy" })
        XCTAssertFalse(project.diagnostics.contains { $0.path.hasPrefix("services.api.build.") })
    }

    func testMergesBuildStringAndObjectFormsAcrossOrderedComposeFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          api:
            image: example/api:dev
            build: ./api
          worker:
            image: example/worker:dev
            build:
              context: ./worker
              dockerfile: Dockerfile.worker
              args:
                BASE: "1"
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          api:
            build:
              dockerfile: Dockerfile.prod
              args:
                BASE: "2"
          worker:
            build: ./worker-alt
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(
            from: [basePath.path, overridePath.path],
            activeProfiles: []
        )
        let api = try XCTUnwrap(project.services.first { $0.name == "api" })
        let worker = try XCTUnwrap(project.services.first { $0.name == "worker" })

        XCTAssertEqual(api.build, ComposeBuild(
            context: "./api",
            dockerfile: "Dockerfile.prod",
            args: ["BASE=2"]
        ))
        XCTAssertEqual(worker.build, ComposeBuild(
            context: "./worker-alt",
            dockerfile: "Dockerfile.worker",
            args: ["BASE=1"]
        ))
    }

    func testLoadsServiceHealthcheckForms() throws {
        let yaml = """
        services:
          api:
            image: backend
            healthcheck:
              test: ["CMD", "curl", "-f", "http://localhost/health"]
              interval: 30s
              timeout: 5s
              retries: 3
              start_period: 10s
              start_interval: 2s
          worker:
            image: busybox
            healthcheck:
              test: echo ok
          disabled:
            image: busybox
            healthcheck:
              test: ["NONE"]
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let api = try XCTUnwrap(project.services.first { $0.name == "api" })
        let worker = try XCTUnwrap(project.services.first { $0.name == "worker" })
        let disabled = try XCTUnwrap(project.services.first { $0.name == "disabled" })

        XCTAssertEqual(api.healthcheck, ComposeHealthcheck(
            test: ["CMD", "curl", "-f", "http://localhost/health"],
            interval: "30s",
            timeout: "5s",
            retries: 3,
            startPeriod: "10s",
            startInterval: "2s"
        ))
        XCTAssertEqual(worker.healthcheck?.test, ["CMD-SHELL", "echo ok"])
        XCTAssertEqual(disabled.healthcheck, ComposeHealthcheck(test: ["NONE"], disabled: true))
        XCTAssertFalse(project.diagnostics.contains { $0.path.contains(".healthcheck") })
    }

    func testLoadsMappedServiceRunOptions() throws {
        let yaml = """
        services:
          web:
            image: nginx
            init: true
            stdin_open: true
            tty: true
            read_only: true
            cap_add:
              - NET_ADMIN
            cap_drop:
              - MKNOD
            dns:
              - 1.1.1.1
            dns_search:
              - svc.local
            dns_opt:
              - ndots:0
            shm_size: 128m
            tmpfs:
              - /run
              - /tmp:size=64m
            ulimits:
              nofile:
                soft: 20000
                hard: 40000
              nproc: 65535
            stop_signal: SIGUSR1
            stop_grace_period: 1m30s
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertTrue(web.initProcess)
        XCTAssertTrue(web.stdinOpen)
        XCTAssertTrue(web.tty)
        XCTAssertTrue(web.readOnly)
        XCTAssertEqual(web.capAdd, ["NET_ADMIN"])
        XCTAssertEqual(web.capDrop, ["MKNOD"])
        XCTAssertEqual(web.dns, ["1.1.1.1"])
        XCTAssertEqual(web.dnsSearch, ["svc.local"])
        XCTAssertEqual(web.dnsOptions, ["ndots:0"])
        XCTAssertEqual(web.shmSize, "128m")
        XCTAssertEqual(web.tmpfs, ["/run", "/tmp:size=64m"])
        XCTAssertEqual(web.ulimits, ["nofile=20000:40000", "nproc=65535"])
        XCTAssertEqual(web.stopSignal, "SIGUSR1")
        XCTAssertEqual(web.stopGracePeriod, "1m30s")
        XCTAssertFalse(project.diagnostics.contains { $0.path.hasPrefix("services.web.") })
    }

    func testReservedComposeServiceLabelProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            labels:
              - com.docker.compose.project=demo
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.labels, [])
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.labels.com.docker.compose.project"
        })
    }

    func testComposeServiceDecodesOlderJSONWithoutLabels() throws {
        let json = """
        {
          "name": "web",
          "image": "nginx"
        }
        """

        let service = try JSONDecoder().decode(ComposeService.self, from: Data(json.utf8))

        XCTAssertEqual(service.name, "web")
        XCTAssertEqual(service.labels, [])
        XCTAssertNil(service.build)
        XCTAssertNil(service.pullPolicy)
        XCTAssertNil(service.healthcheck)
        XCTAssertFalse(service.initProcess)
        XCTAssertFalse(service.stdinOpen)
        XCTAssertFalse(service.tty)
        XCTAssertFalse(service.readOnly)
        XCTAssertEqual(service.capAdd, [])
        XCTAssertEqual(service.capDrop, [])
        XCTAssertEqual(service.securityOptions, [])
        XCTAssertEqual(service.annotations, [])
        XCTAssertNil(service.attach)
        XCTAssertNil(service.blockIOConfig)
        XCTAssertNil(service.runtime)
        XCTAssertNil(service.scale)
        XCTAssertEqual(service.storageOptions, [:])
        XCTAssertNil(service.useAPISocket)
        XCTAssertNil(service.provider)
        XCTAssertNil(service.credentialSpec)
        XCTAssertEqual(service.volumesFrom, [])
        XCTAssertEqual(service.postStartHooks, [])
        XCTAssertEqual(service.preStartHooks, [])
        XCTAssertEqual(service.preStopHooks, [])
        XCTAssertNil(service.cpuCount)
        XCTAssertNil(service.cpuPercent)
        XCTAssertNil(service.cpuShares)
        XCTAssertNil(service.cpuPeriod)
        XCTAssertNil(service.cpuQuota)
        XCTAssertNil(service.cpuRTRuntime)
        XCTAssertNil(service.cpuRTPeriod)
        XCTAssertNil(service.cpuSet)
        XCTAssertEqual(service.dns, [])
        XCTAssertEqual(service.dnsSearch, [])
        XCTAssertEqual(service.dnsOptions, [])
        XCTAssertNil(service.shmSize)
        XCTAssertEqual(service.tmpfs, [])
        XCTAssertEqual(service.ulimits, [])
        XCTAssertNil(service.stopSignal)
        XCTAssertNil(service.stopGracePeriod)
        XCTAssertEqual(service.labelFiles, [])
        XCTAssertNil(service.containerName)
        XCTAssertNil(service.hostname)
        XCTAssertNil(service.domainName)
        XCTAssertNil(service.networkMode)
        XCTAssertNil(service.pidMode)
        XCTAssertNil(service.ipcMode)
        XCTAssertNil(service.utsMode)
        XCTAssertNil(service.usernsMode)
        XCTAssertNil(service.isolation)
        XCTAssertNil(service.cgroupMode)
        XCTAssertNil(service.cgroupParent)
        XCTAssertEqual(service.deviceCgroupRules, [])
        XCTAssertEqual(service.devices, [])
        XCTAssertNil(service.gpus)
        XCTAssertEqual(service.groupAdd, [])
        XCTAssertEqual(service.sysctls, [:])
        XCTAssertNil(service.oomKillDisable)
        XCTAssertNil(service.oomScoreAdjustment)
        XCTAssertNil(service.pidsLimit)
        XCTAssertNil(service.logging)
        XCTAssertEqual(service.links, [])
        XCTAssertEqual(service.externalLinks, [])
        XCTAssertNil(service.memoryReservation)
        XCTAssertNil(service.memorySwappiness)
        XCTAssertNil(service.macAddress)
        XCTAssertEqual(service.exposedPorts, [])
        XCTAssertNil(service.privileged)
    }

    func testLoadsServiceContainerName() throws {
        let yaml = """
        services:
          web:
            image: nginx
            container_name: public-web
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.containerName, "public-web")
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.container_name" })
    }

    func testLoadsServiceHostname() throws {
        let yaml = """
        services:
          web:
            image: nginx
            hostname: web-01.example.local
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.hostname, "web-01.example.local")
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.hostname" })
    }

    func testInvalidServiceHostnameProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            hostname: -bad.host
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.hostname)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.hostname"
            && $0.message == "hostname must be a valid RFC 1123 hostname."
        })
    }

    func testLoadsServiceDomainName() throws {
        let yaml = """
        services:
          web:
            image: nginx
            domainname: example.local
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.domainName, "example.local")
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.domainname" })
    }

    func testInvalidServiceDomainNameProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            domainname: bad_domain
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.domainName)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.domainname"
            && $0.message == "domainname must be a valid RFC 1123 hostname."
        })
    }

    func testLoadsServiceNetworkMode() throws {
        let yaml = """
        services:
          web:
            image: nginx
            network_mode: host
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.networkMode, "host")
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.network_mode" })
    }

    func testEmptyServiceNetworkModeProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            network_mode: ""
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.networkMode)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.network_mode"
            && $0.message == "Expected a non-empty network_mode string."
        })
    }

    func testServiceNetworkModeCannotBeUsedWithNetworks() throws {
        let yaml = """
        services:
          web:
            image: nginx
            network_mode: host
            networks:
              - front
        networks:
          front: {}
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.networkMode, "host")
        XCTAssertEqual(project.services.first?.networks, ["front"])
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.network_mode"
            && $0.message == "network_mode cannot be used together with networks."
        })
    }

    func testServiceNamespaceReferencesContributeDependencies() throws {
        let yaml = """
        services:
          cache:
            image: redis
          db:
            image: postgres
          sidecar:
            image: busybox
          web:
            image: nginx
            network_mode: service:db
            pid: service:sidecar
            ipc: service:cache
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.networkMode, "service:db")
        XCTAssertEqual(web.pidMode, "service:sidecar")
        XCTAssertEqual(web.ipcMode, "service:cache")
        XCTAssertEqual(web.dependsOn, ["db", "sidecar", "cache"])
        XCTAssertEqual(web.dependsOnMetadata["db"], ComposeServiceDependencyMetadata())
        XCTAssertEqual(web.dependsOnMetadata["sidecar"], ComposeServiceDependencyMetadata())
        XCTAssertEqual(web.dependsOnMetadata["cache"], ComposeServiceDependencyMetadata())
        XCTAssertFalse(project.diagnostics.contains { $0.path.contains("depends_on") })
    }

    func testExplicitDependsOnDeduplicatesServiceNamespaceReferences() throws {
        let yaml = """
        services:
          db:
            image: postgres
          web:
            image: nginx
            depends_on:
              db:
                condition: service_started
            network_mode: service:db
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.dependsOn, ["db"])
        XCTAssertEqual(web.dependsOnMetadata["db"], ComposeServiceDependencyMetadata())
    }

    func testLoadsServiceMACAddress() throws {
        let yaml = """
        services:
          web:
            image: nginx
            mac_address: 02:42:ac:11:00:02
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.macAddress, "02:42:ac:11:00:02")
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.mac_address" })
    }

    func testLoadsCompactServiceMACAddress() throws {
        let yaml = """
        services:
          web:
            image: nginx
            mac_address: 0242AC110002
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.macAddress, "0242AC110002")
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.mac_address" })
    }

    func testInvalidServiceMACAddressProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            mac_address: 02:42:ac:11:00
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.macAddress)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.mac_address"
            && $0.message == "mac_address must be a valid MAC address."
        })
    }

    func testLoadsServicePIDMode() throws {
        let yaml = """
        services:
          web:
            image: nginx
            pid: host
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.pidMode, "host")
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.pid" })
    }

    func testEmptyServicePIDModeProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            pid: ""
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.pidMode)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.pid"
            && $0.message == "Expected a non-empty pid string."
        })
    }

    func testLoadsServiceIPCMode() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ipc: shareable
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.ipcMode, "shareable")
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.ipc" })
    }

    func testEmptyServiceIPCModeProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ipc: ""
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.ipcMode)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.ipc"
            && $0.message == "Expected a non-empty ipc string."
        })
    }

    func testLoadsServiceUTSMode() throws {
        let yaml = """
        services:
          web:
            image: nginx
            uts: host
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.utsMode, "host")
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.uts" })
    }

    func testEmptyServiceUTSModeProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            uts: ""
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.utsMode)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.uts"
            && $0.message == "Expected a non-empty uts string."
        })
    }

    func testLoadsServiceUserNamespaceMode() throws {
        let yaml = """
        services:
          web:
            image: nginx
            userns_mode: host
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.usernsMode, "host")
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.userns_mode" })
    }

    func testEmptyServiceUserNamespaceModeProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            userns_mode: ""
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.usernsMode)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.userns_mode"
            && $0.message == "Expected a non-empty userns_mode string."
        })
    }

    func testLoadsServiceCgroupMode() throws {
        let yaml = """
        services:
          web:
            image: nginx
            cgroup: private
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.cgroupMode, "private")
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.cgroup" })
    }

    func testInvalidServiceCgroupModeProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            cgroup: shared
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.cgroupMode)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.cgroup"
            && $0.message == "cgroup must be either 'host' or 'private'."
        })
    }

    func testLoadsServiceIsolation() throws {
        let yaml = """
        services:
          web:
            image: nginx
            isolation: hyperv
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.isolation, "hyperv")
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.isolation" })
    }

    func testInvalidServiceIsolationProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            isolation: ""
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.isolation)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.isolation"
            && $0.message == "Expected a non-empty isolation string."
        })
    }

    func testLoadsServiceCgroupParent() throws {
        let yaml = """
        services:
          web:
            image: nginx
            cgroup_parent: m-executor-abcd
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.cgroupParent, "m-executor-abcd")
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.cgroup_parent" })
    }

    func testEmptyServiceCgroupParentProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            cgroup_parent: ""
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.cgroupParent)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.cgroup_parent"
            && $0.message == "Expected a non-empty cgroup_parent string."
        })
    }

    func testLoadsServiceDeviceCgroupRules() throws {
        let yaml = """
        services:
          web:
            image: nginx
            device_cgroup_rules:
              - 'c 1:3 mr'
              - 'a 7:* rmw'
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.deviceCgroupRules, ["c 1:3 mr", "a 7:* rmw"])
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.device_cgroup_rules" })
    }

    func testInvalidServiceDeviceCgroupRulesProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            device_cgroup_rules:
              - 'c 1:3 mr'
              - { rule: invalid }
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.deviceCgroupRules, ["c 1:3 mr"])
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.device_cgroup_rules[1]"
            && $0.message == "Expected a string value."
        })
    }

    func testLoadsServiceDevices() throws {
        let yaml = """
        services:
          web:
            image: nginx
            devices:
              - "/dev/ttyUSB0:/dev/ttyUSB0"
              - "vendor1.com/device=gpu"
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.devices, ["/dev/ttyUSB0:/dev/ttyUSB0", "vendor1.com/device=gpu"])
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.devices" })
    }

    func testMergesServiceDevicesByContainerTargetAcrossOrderedComposeFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: nginx
            devices:
              - "/dev/ttyUSB0:/dev/ttyUSB0:rwm"
              - "vendor1.com/device=gpu"
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          web:
            devices:
              - "/dev/ttyACM0:/dev/ttyUSB0:rw"
              - "/dev/vgpu0:/dev/vgpu0"
              - "vendor1.com/device=gpu"
              - "vendor2.com/device=gpu"
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(
            from: [basePath.path, overridePath.path],
            activeProfiles: []
        )

        XCTAssertEqual(project.services.first?.devices, [
            "/dev/ttyACM0:/dev/ttyUSB0:rw",
            "vendor1.com/device=gpu",
            "/dev/vgpu0:/dev/vgpu0",
            "vendor2.com/device=gpu"
        ])
    }

    func testInvalidServiceDevicesProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            devices:
              - "/dev/ttyUSB0:/dev/ttyUSB0"
              - ""
              - { path: /dev/sda }
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.devices, ["/dev/ttyUSB0:/dev/ttyUSB0"])
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.devices[1]"
            && $0.message == "Expected a non-empty device mapping string."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.devices[2]"
            && $0.message == "Expected a non-empty device mapping string."
        })
    }

    func testLoadsServiceGPUsAll() throws {
        let yaml = """
        services:
          model:
            image: local/model
            gpus: all
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.gpus, ComposeGPURequest(all: true))
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.model.gpus" })
    }

    func testLoadsServiceGPUDeviceRequests() throws {
        let yaml = """
        services:
          model:
            image: local/model
            gpus:
              - driver: 3dfx
                count: 2
                device_ids:
                  - gpu-1
                capabilities:
                  - compute
                  - utility
                options:
                  mode: fast
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(
            project.services.first?.gpus,
            ComposeGPURequest(
                devices: [
                    ComposeGPUDeviceRequest(
                        driver: "3dfx",
                        count: "2",
                        deviceIDs: ["gpu-1"],
                        capabilities: ["compute", "utility"],
                        options: ["mode": "fast"]
                    )
                ]
            )
        )
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.model.gpus" })
    }

    func testInvalidServiceGPUsProducesDiagnostic() throws {
        let yaml = """
        services:
          model:
            image: local/model
            gpus: partial
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.gpus)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.model.gpus"
            && $0.message == "gpus must be 'all' or a list of GPU device requests."
        })
    }

    func testInvalidServiceGPUDeviceRequestProducesDiagnostic() throws {
        let yaml = """
        services:
          model:
            image: local/model
            gpus:
              - driver: metal
              - invalid
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.gpus, ComposeGPURequest(devices: [ComposeGPUDeviceRequest(driver: "metal")]))
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.model.gpus[1]"
            && $0.message == "Expected a GPU device request mapping."
        })
    }

    func testLoadsServiceGroupAdd() throws {
        let yaml = """
        services:
          web:
            image: alpine
            group_add:
              - mail
              - 44
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.groupAdd, ["mail", "44"])
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.group_add" })
    }

    func testInvalidServiceGroupAddProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: alpine
            group_add:
              - mail
              - ""
              - { name: staff }
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.groupAdd, ["mail"])
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.group_add[1]"
            && $0.message == "Expected a non-empty group name or ID."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.group_add[2]"
            && $0.message == "Expected a non-empty group name or ID."
        })
    }

    func testLoadsServiceSysctlsMap() throws {
        let yaml = """
        services:
          web:
            image: nginx
            sysctls:
              net.core.somaxconn: 1024
              net.ipv4.tcp_syncookies: 0
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.sysctls, [
            "net.core.somaxconn": "1024",
            "net.ipv4.tcp_syncookies": "0"
        ])
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.sysctls" })
    }

    func testLoadsServiceSysctlsList() throws {
        let yaml = """
        services:
          web:
            image: nginx
            sysctls:
              - net.core.somaxconn=1024
              - net.ipv4.tcp_syncookies=0
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.sysctls, [
            "net.core.somaxconn": "1024",
            "net.ipv4.tcp_syncookies": "0"
        ])
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.sysctls" })
    }

    func testInvalidServiceSysctlsProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            sysctls:
              - net.core.somaxconn=1024
              - invalid
              - ""
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.sysctls, ["net.core.somaxconn": "1024"])
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.sysctls[1]"
            && $0.message == "Expected a sysctl entry in KEY=VALUE form."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.sysctls[2]"
            && $0.message == "Expected a non-empty sysctl entry."
        })
    }

    func testLoadsServiceOOMControls() throws {
        let yaml = """
        services:
          worker:
            image: alpine
            oom_kill_disable: true
            oom_score_adj: -500
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.oomKillDisable, true)
        XCTAssertEqual(project.services.first?.oomScoreAdjustment, -500)
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.worker.oom_kill_disable" })
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.worker.oom_score_adj" })
    }

    func testInvalidServiceOOMScoreAdjustmentProducesDiagnostic() throws {
        let yaml = """
        services:
          worker:
            image: alpine
            oom_score_adj: 1001
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.oomScoreAdjustment)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.worker.oom_score_adj"
            && $0.message == "oom_score_adj must be within the [-1000, 1000] range."
        })
    }

    func testInvalidServiceOOMKillDisableProducesDiagnostic() throws {
        let yaml = """
        services:
          worker:
            image: alpine
            oom_kill_disable: maybe
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.oomKillDisable)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.worker.oom_kill_disable"
            && $0.message == "Expected a boolean value."
        })
    }

    func testLoadsServicePIDsLimit() throws {
        let yaml = """
        services:
          worker:
            image: alpine
            pids_limit: -1
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.pidsLimit, -1)
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.worker.pids_limit" })
    }

    func testInvalidServicePIDsLimitProducesDiagnostic() throws {
        let yaml = """
        services:
          worker:
            image: alpine
            pids_limit: -2
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.pidsLimit)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.worker.pids_limit"
            && $0.message == "pids_limit must be -1 or greater."
        })
    }

    func testLoadsServiceLoggingConfig() throws {
        let yaml = """
        services:
          web:
            image: nginx
            logging:
              driver: json-file
              options:
                max-size: 10m
                max-file: 3
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.logging, ComposeLogging(
            driver: "json-file",
            options: [
                "max-size": "10m",
                "max-file": "3"
            ]
        ))
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.logging" })
    }

    func testMergesLoggingOptionsWhenDriverMatchesAcrossOrderedComposeFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: nginx
            logging:
              driver: json-file
              options:
                max-size: 10m
                max-file: 3
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          web:
            logging:
              driver: json-file
              options:
                max-file: 5
                compress: true
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: [basePath.path, overridePath.path])

        XCTAssertEqual(project.services.first?.logging, ComposeLogging(
            driver: "json-file",
            options: [
                "max-size": "10m",
                "max-file": "5",
                "compress": "true"
            ]
        ))
        XCTAssertTrue(project.diagnostics.isEmpty)
    }

    func testReplacesLoggingConfigWhenDriverChangesAcrossOrderedComposeFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: nginx
            logging:
              driver: json-file
              options:
                max-size: 10m
                max-file: 3
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          web:
            logging:
              driver: syslog
              options:
                syslog-address: tcp://127.0.0.1:123
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: [basePath.path, overridePath.path])

        XCTAssertEqual(project.services.first?.logging, ComposeLogging(
            driver: "syslog",
            options: [
                "syslog-address": "tcp://127.0.0.1:123"
            ]
        ))
        XCTAssertTrue(project.diagnostics.isEmpty)
    }

    func testInvalidServiceLoggingProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            logging: syslog
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.logging)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.logging"
            && $0.message == "Expected a logging mapping."
        })
    }

    func testLoadsServiceRuntimeScaleStorageOptionsAndAPISocket() throws {
        let yaml = """
        services:
          web:
            image: nginx
            runtime: io.containerd.runc.v2
            scale: 3
            storage_opt:
              size: 1G
              backing: true
            use_api_socket: true
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let service = try XCTUnwrap(project.services.first)

        XCTAssertEqual(service.runtime, "io.containerd.runc.v2")
        XCTAssertEqual(service.scale, 3)
        XCTAssertEqual(service.storageOptions, [
            "size": "1G",
            "backing": "true"
        ])
        XCTAssertEqual(service.useAPISocket, true)
        XCTAssertFalse(project.diagnostics.contains {
            $0.path == "services.web.runtime"
            || $0.path == "services.web.scale"
            || $0.path == "services.web.storage_opt"
            || $0.path == "services.web.use_api_socket"
        })
    }

    func testInvalidServiceRuntimeScaleStorageOptionsAndAPISocketProduceDiagnostics() throws {
        let yaml = """
        services:
          web:
            image: nginx
            runtime: []
            scale: -1
            storage_opt:
              - size=1G
            use_api_socket: maybe
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let service = try XCTUnwrap(project.services.first)

        XCTAssertNil(service.runtime)
        XCTAssertNil(service.scale)
        XCTAssertEqual(service.storageOptions, [:])
        XCTAssertNil(service.useAPISocket)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.runtime"
            && $0.message == "Expected a non-empty string."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.scale"
            && $0.message == "scale must be 0 or greater."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.storage_opt"
            && $0.message == "Expected a string mapping."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.use_api_socket"
            && $0.message == "Expected a boolean value."
        })
    }

    func testLoadsServiceLifecycleHooks() throws {
        let yaml = """
        services:
          web:
            image: nginx
            post_start:
              - command: ./after-start.sh
                user: root
                privileged: true
                working_dir: /app
                environment:
                  FOO: BAR
            pre_start:
              - command: ["./manage.py", "migrate"]
                image: python:3.12
                per_replica: true
                environment:
                  - DJANGO_SETTINGS_MODULE=prod
              - image: busybox
            pre_stop:
              - command: ./before-stop.sh
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let service = try XCTUnwrap(project.services.first)

        XCTAssertEqual(service.postStartHooks, [
            ComposeLifecycleHook(
                command: ["./after-start.sh"],
                user: "root",
                privileged: true,
                workingDirectory: "/app",
                environment: ["FOO": "BAR"]
            )
        ])
        XCTAssertEqual(service.preStartHooks, [
            ComposeLifecycleHook(
                command: ["./manage.py", "migrate"],
                image: "python:3.12",
                environment: ["DJANGO_SETTINGS_MODULE": "prod"],
                perReplica: true
            ),
            ComposeLifecycleHook(image: "busybox")
        ])
        XCTAssertEqual(service.preStopHooks, [
            ComposeLifecycleHook(command: ["./before-stop.sh"])
        ])
        XCTAssertFalse(project.diagnostics.contains {
            $0.path == "services.web.post_start"
            || $0.path == "services.web.pre_start"
            || $0.path == "services.web.pre_stop"
        })
    }

    func testInvalidServiceLifecycleHooksProduceDiagnostics() throws {
        let yaml = """
        services:
          web:
            image: nginx
            post_start:
              - user: root
            pre_start: ./setup.sh
            pre_stop:
              - []
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let service = try XCTUnwrap(project.services.first)

        XCTAssertEqual(service.postStartHooks, [
            ComposeLifecycleHook(user: "root")
        ])
        XCTAssertEqual(service.preStartHooks, [])
        XCTAssertEqual(service.preStopHooks, [])
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.post_start[0].command"
            && $0.message == "Lifecycle hook command is required."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.pre_start"
            && $0.message == "Expected a list of lifecycle hook mappings."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.pre_stop[0]"
            && $0.message == "Expected a mapping for lifecycle hook."
        })
    }

    func testLoadsServiceProvider() throws {
        let yaml = """
        services:
          database:
            provider:
              type: awesomecloud
              options:
                type: mysql
                plan: dev
                replicas: 2
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let service = try XCTUnwrap(project.services.first)

        XCTAssertEqual(service.provider, ComposeProvider(
            type: "awesomecloud",
            options: [
                "type": "mysql",
                "plan": "dev",
                "replicas": "2"
            ]
        ))
        XCTAssertFalse(project.diagnostics.contains {
            $0.path == "services.database.provider"
            || $0.path == "services.database.provider.type"
            || $0.path == "services.database.provider.options"
        })
    }

    func testInvalidServiceProviderProducesDiagnostics() throws {
        let yaml = """
        services:
          database:
            provider:
              options:
                - type=mysql
          cache:
            provider: awesomecloud
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let database = try XCTUnwrap(project.services.first { $0.name == "database" })
        let cache = try XCTUnwrap(project.services.first { $0.name == "cache" })

        XCTAssertNil(database.provider)
        XCTAssertNil(cache.provider)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.database.provider.type"
            && $0.message == "provider.type is required."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.cache.provider"
            && $0.message == "Expected a mapping for provider."
        })
    }

    func testLoadsServiceCredentialSpec() throws {
        let yaml = """
        services:
          web:
            image: mcr.microsoft.com/windows/servercore
            credential_spec:
              file: my-credential-spec.json
          worker:
            image: mcr.microsoft.com/windows/servercore
            credential_spec:
              registry: my-credential-spec
          api:
            image: mcr.microsoft.com/windows/servercore
            credential_spec:
              config: my_credential_spec
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })
        let worker = try XCTUnwrap(project.services.first { $0.name == "worker" })
        let api = try XCTUnwrap(project.services.first { $0.name == "api" })

        XCTAssertEqual(web.credentialSpec, ComposeCredentialSpec(file: "my-credential-spec.json"))
        XCTAssertEqual(worker.credentialSpec, ComposeCredentialSpec(registry: "my-credential-spec"))
        XCTAssertEqual(api.credentialSpec, ComposeCredentialSpec(config: "my_credential_spec"))
        XCTAssertFalse(project.diagnostics.contains {
            $0.path.hasPrefix("services.web.credential_spec")
            || $0.path.hasPrefix("services.worker.credential_spec")
            || $0.path.hasPrefix("services.api.credential_spec")
        })
    }

    func testInvalidServiceCredentialSpecProducesDiagnostics() throws {
        let yaml = """
        services:
          web:
            image: nginx
            credential_spec: file://my-credential-spec.json
          worker:
            image: nginx
            credential_spec: {}
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })
        let worker = try XCTUnwrap(project.services.first { $0.name == "worker" })

        XCTAssertNil(web.credentialSpec)
        XCTAssertNil(worker.credentialSpec)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.credential_spec"
            && $0.message == "Expected a mapping for credential_spec."
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.worker.credential_spec"
            && $0.message == "credential_spec requires file, registry, or config."
        })
    }

    func testLoadsServiceVolumesFromAndInfersServiceDependencies() throws {
        let yaml = """
        services:
          data:
            image: busybox
          app:
            image: nginx
            volumes_from:
              - data
              - data:ro
              - container:legacy-data
              - container:legacy-cache:rw
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let app = try XCTUnwrap(project.services.first { $0.name == "app" })

        XCTAssertEqual(app.volumesFrom, [
            "data",
            "data:ro",
            "container:legacy-data",
            "container:legacy-cache:rw"
        ])
        XCTAssertEqual(app.dependsOn, ["data"])
        XCTAssertEqual(app.dependsOnMetadata, [
            "data": ComposeServiceDependencyMetadata()
        ])
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.app.volumes_from" })
    }

    func testInvalidServiceVolumesFromProducesDiagnostics() throws {
        let yaml = """
        services:
          app:
            image: nginx
            volumes_from:
              source: data
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let app = try XCTUnwrap(project.services.first)

        XCTAssertEqual(app.volumesFrom, [])
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.app.volumes_from"
            && $0.message == "Expected a string or list of strings."
        })
    }

    func testLoadsServiceMemoryReservationAndSwappiness() throws {
        let yaml = """
        services:
          web:
            image: nginx
            mem_reservation: 256m
            mem_swappiness: 25
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertEqual(project.services.first?.memoryReservation, "256m")
        XCTAssertEqual(project.services.first?.memorySwappiness, 25)
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.mem_reservation" })
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.mem_swappiness" })
    }

    func testInvalidServiceMemorySwappinessProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            mem_swappiness: 101
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.memorySwappiness)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.mem_swappiness"
            && $0.message == "mem_swappiness must be within the [0, 100] range."
        })
    }

    func testInvalidServiceContainerNameProducesDiagnosticAndFallsBack() throws {
        let yaml = """
        services:
          web:
            image: nginx
            container_name: -invalid
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.containerName)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.container_name"
        })
    }

    func testNonASCIIServiceContainerNameProducesDiagnosticAndFallsBack() throws {
        let yaml = """
        services:
          web:
            image: nginx
            container_name: ábc
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertNil(project.services.first?.containerName)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.container_name"
            && $0.message.contains("[a-zA-Z0-9][a-zA-Z0-9_.-]+")
        })
    }

    func testDuplicateServiceContainerNamesProduceDiagnostic() throws {
        let yaml = """
        services:
          api:
            image: backend
            container_name: shared
          web:
            image: nginx
            container_name: shared
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.container_name"
            && $0.message.contains("api")
        })
    }

    func testExplicitContainerNameCannotCollideWithGeneratedName() throws {
        let yaml = """
        name: demo
        services:
          api:
            image: backend
            container_name: demo_db_1
          db:
            image: postgres
        """

        let project = try ComposeLoader().load(yaml: yaml)

        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.db"
            && $0.message.contains("api")
        })
    }

    func testIncludesCopyConfigsAndSecretsIntoCurrentProject() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try FileManager.default.createDirectory(
            at: workdir.appendingPathComponent("shared"),
            withIntermediateDirectories: true
        )

        try """
        services:
          worker:
            image: busybox
            configs:
              - shared-config
            secrets:
              - shared-secret
        configs:
          shared-config:
            file: ./shared.conf
        secrets:
          shared-secret:
            file: ./shared.secret
        """.write(to: workdir.appendingPathComponent("shared/compose.yaml"), atomically: true, encoding: .utf8)

        try """
        include:
          - shared/compose.yaml
        services:
          web:
            image: nginx
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)

        XCTAssertEqual(project.services.map(\.name), ["web", "worker"])
        XCTAssertEqual(project.configs["shared-config"]?.file, "./shared.conf")
        XCTAssertEqual(project.secrets["shared-secret"]?.file, "./shared.secret")
    }

    func testOverridesConfigAndSecretServiceGrantsByTarget() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        let overridePath = workdir.appendingPathComponent("compose.override.yaml")

        try """
        services:
          web:
            image: nginx
            configs:
              - source: base-config
                target: /etc/app/config.yml
            secrets:
              - source: base-secret
                target: password
        configs:
          base-config:
            file: ./base.yml
        secrets:
          base-secret:
            file: ./base.secret
        """.write(to: basePath, atomically: true, encoding: .utf8)

        try """
        services:
          web:
            configs:
              - source: override-config
                target: /etc/app/config.yml
            secrets:
              - source: override-secret
                target: password
        configs:
          override-config:
            file: ./override.yml
        secrets:
          override-secret:
            file: ./override.secret
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: [basePath.path, overridePath.path])
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.configs, [
            ComposeServiceResourceGrant(source: "override-config", target: "/etc/app/config.yml")
        ])
        XCTAssertEqual(web.secrets, [
            ComposeServiceResourceGrant(source: "override-secret", target: "/run/secrets/password")
        ])
    }

    func testFiltersProfiles() throws {
        let yaml = """
        services:
          web:
            image: nginx
          debug:
            image: busybox
            profiles: [debug]
        """

        let inactive = try ComposeLoader().load(yaml: yaml, activeProfiles: [])
        XCTAssertEqual(inactive.services.map(\.name), ["web"])

        let active = try ComposeLoader().load(yaml: yaml, activeProfiles: ["debug"])
        XCTAssertEqual(active.services.map(\.name), ["debug", "web"])
    }

    func testTargetedServicesActivateTheirProfiles() throws {
        let yaml = """
        services:
          web:
            image: nginx
          debug:
            image: busybox
            profiles: [debug]
        """

        let project = try ComposeLoader().load(
            yaml: yaml,
            activeProfiles: [],
            targetedServices: ["debug"]
        )

        XCTAssertEqual(project.services.map(\.name), ["debug", "web"])
    }

    func testTargetedProfiledServicesActivateSharedProfileDependencies() throws {
        let yaml = """
        services:
          db:
            image: postgres
            profiles: [test]
          app:
            image: app
            depends_on:
              - db
            profiles: [test]
          web:
            image: nginx
        """

        let project = try ComposeLoader().load(
            yaml: yaml,
            activeProfiles: [],
            targetedServices: ["app"]
        )

        XCTAssertEqual(project.services.map(\.name), ["app", "db", "web"])
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.app.depends_on.db" })
    }

    func testTargetingProfiledServiceDoesNotActivateUnrelatedDependencyProfile() throws {
        let yaml = """
        services:
          bar:
            image: bar
            profiles: [test]
          zot:
            image: zot
            depends_on:
              - bar
            profiles: [debug]
        """

        let project = try ComposeLoader().load(
            yaml: yaml,
            activeProfiles: [],
            targetedServices: ["zot"]
        )

        XCTAssertEqual(project.services.map(\.name), ["zot"])
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.zot.depends_on.bar"
        })
    }

    func testActiveProfileDoesNotAutomaticallyActivateDependencyProfile() throws {
        let yaml = """
        services:
          bar:
            image: bar
            profiles: [test]
          zot:
            image: zot
            depends_on:
              - bar
            profiles: [debug]
        """

        let project = try ComposeLoader().load(yaml: yaml, activeProfiles: ["debug"])

        XCTAssertEqual(project.services.map(\.name), ["zot"])
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.zot.depends_on.bar"
        })
    }

    func testTargetedServiceWithUndefinedDependencyProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            depends_on:
              - db
            profiles: [debug]
        """

        let project = try ComposeLoader().load(
            yaml: yaml,
            activeProfiles: [],
            targetedServices: ["web"]
        )

        XCTAssertEqual(project.services.map(\.name), ["web"])
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.web.depends_on.db"
            && $0.message.contains("not defined")
        })
    }

    func testLoadsComposeFromDirectoryEnvFileInterpolation() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        IMAGE=nginx:alpine
        """.write(to: workdir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let composePath = workdir.appendingPathComponent("compose.yaml")
        try """
        name: ${PROJECT:-container-compose}
        services:
          web:
            image: ${IMAGE:-busybox}
        """.write(to: composePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(
            from: composePath.path,
            activeProfiles: []
        )

        XCTAssertEqual(project.name, "container-compose")
        XCTAssertEqual(project.services.map(\.name), ["web"])
        XCTAssertEqual(project.services.first?.image, "nginx:alpine")
    }

    func testLoaderUsesExplicitEnvFilesForInterpolationInsteadOfDefaultDotEnv() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try "IMAGE=from-dot-env\nTAG=dot\n".write(
            to: workdir.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
        try "IMAGE=redis\nTAG=7\n".write(
            to: workdir.appendingPathComponent("defaults.env"),
            atomically: true,
            encoding: .utf8
        )
        try "TAG=7-alpine\n".write(
            to: workdir.appendingPathComponent("local.env"),
            atomically: true,
            encoding: .utf8
        )

        try """
        services:
          cache:
            image: ${IMAGE}:${TAG}
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader(envFiles: ["defaults.env", "local.env"]).load(
            workingDirectory: workdir.path
        )

        XCTAssertEqual(project.services.first?.image, "redis:7-alpine")
    }

    func testLoaderCarriesInterpolationWarningsIntoDiagnostics() throws {
        let yaml = """
        services:
          web:
            image: nginx:${TAG}
        """

        let project = try ComposeLoader().load(yaml: yaml, sourcePath: "/tmp/demo/compose.yaml")

        XCTAssertEqual(project.services.first?.image, "nginx:")
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .warning && $0.path == "environment.TAG"
        })
    }

    func testLoaderCanSkipInterpolationForConfigRendering() throws {
        let yaml = """
        services:
          web:
            image: nginx:${TAG}
            environment:
              STATIC: ${VALUE:-fallback}
          worker:
            image: ${WORKER_IMAGE}
        """

        let project = try ComposeLoader(interpolate: false).load(yaml: yaml, sourcePath: "/tmp/demo/compose.yaml")
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })
        let worker = try XCTUnwrap(project.services.first { $0.name == "worker" })

        XCTAssertEqual(web.image, "nginx:${TAG}")
        XCTAssertEqual(web.environment["STATIC"], "${VALUE:-fallback}")
        XCTAssertEqual(worker.image, "${WORKER_IMAGE}")
        XCTAssertFalse(project.diagnostics.contains { $0.path.hasPrefix("environment.") })
    }

    func testInterpolationDoesNotChangeMappingKeys() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        ENV_KEY=DYNAMIC
        ENV_VALUE=value
        """.write(to: workdir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let composePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: nginx
            environment:
              $ENV_KEY: $ENV_VALUE
              STATIC: $ENV_VALUE
          worker:
            image: busybox
            environment:
              - "$ENV_KEY=$ENV_VALUE"
        """.write(to: composePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: composePath.path)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })
        let worker = try XCTUnwrap(project.services.first { $0.name == "worker" })

        XCTAssertEqual(web.environment["$ENV_KEY"], "value")
        XCTAssertNil(web.environment["DYNAMIC"])
        XCTAssertEqual(web.environment["STATIC"], "value")
        XCTAssertEqual(worker.environment["DYNAMIC"], "value")
    }

    func testInterpolationDoesNotRewriteServiceKeys() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try "SUFFIX=api\n".write(to: workdir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        try """
        services:
          app-${SUFFIX}:
            image: nginx
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)

        XCTAssertEqual(project.services.map(\.name), ["app-${SUFFIX}"])
    }

    func testInterpolationTraversesListValues() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        CMD=echo
        DEP=db
        """.write(to: workdir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        try """
        services:
          db:
            image: postgres
          web:
            image: busybox
            command: ["${CMD}", "hello"]
            depends_on:
              - ${DEP}
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.command, ["echo", "hello"])
        XCTAssertEqual(web.dependsOn, ["db"])
        XCTAssertEqual(web.dependsOnMetadata["db"], ComposeServiceDependencyMetadata())
    }

    func testLoadsDependsOnLongFormWithConditionRequiredAndRestart() throws {
        let yaml = """
        services:
          db:
            image: postgres
          cache:
            image: redis
          web:
            image: nginx
            depends_on:
              db:
                condition: service_healthy
                restart: true
                required: false
              cache:
                condition: service_started
        """

        let project = try ComposeLoader().load(yaml: yaml, sourcePath: "/tmp/demo/compose.yaml")
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.dependsOn, ["cache", "db"])
        XCTAssertEqual(web.dependsOnMetadata["db"], ComposeServiceDependencyMetadata(
            condition: .serviceHealthy,
            restart: true,
            required: false
        ))
        XCTAssertEqual(web.dependsOnMetadata["cache"], ComposeServiceDependencyMetadata(
            condition: .serviceStarted,
            restart: false,
            required: true
        ))
    }

    func testLoadsServiceLinksAndExternalLinks() throws {
        let yaml = """
        services:
          db:
            image: postgres
          cache:
            image: redis
          web:
            image: nginx
            links:
              - db:database
              - cache
            external_links:
              - redis
              - database:mysql
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.links, ["db:database", "cache"])
        XCTAssertEqual(web.externalLinks, ["redis", "database:mysql"])
        XCTAssertEqual(web.dependsOn, ["db", "cache"])
        XCTAssertEqual(web.dependsOnMetadata["db"], ComposeServiceDependencyMetadata())
        XCTAssertEqual(web.dependsOnMetadata["cache"], ComposeServiceDependencyMetadata())
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.links" })
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.external_links" })
    }

    func testDependsOnLongFormInvalidValuesWarnAndUseDefaults() throws {
        let yaml = """
        services:
          db:
            image: postgres
          web:
            image: nginx
            depends_on:
              db:
                condition: eventually
                restart: sometimes
                required: maybe
                extra: ignored
        """

        let project = try ComposeLoader().load(yaml: yaml, sourcePath: "/tmp/demo/compose.yaml")
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.dependsOnMetadata["db"], ComposeServiceDependencyMetadata())
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.web.depends_on.db.condition"
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.web.depends_on.db.restart"
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.web.depends_on.db.required"
        })
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "services.web.depends_on.db.extra"
        })
    }

    func testInterpolationTraversesNestedValues() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        PORT_TARGET=80
        PORT_PUBLISHED=8080
        READ_ONLY=true
        """.write(to: workdir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        try """
        services:
          web:
            image: nginx
            ports:
              - target: ${PORT_TARGET}
                published: ${PORT_PUBLISHED}
            volumes:
              - type: bind
                source: ./config
                target: /etc/config
                read_only: ${READ_ONLY}
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.ports, ["8080:80"])
        XCTAssertEqual(web.volumes, ["./config:/etc/config:ro"])
    }

    func testIncludePathValuesAreInterpolatedAfterYamlParse() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try FileManager.default.createDirectory(
            at: workdir.appendingPathComponent("shared"),
            withIntermediateDirectories: true
        )

        try "INCLUDE_FILE=shared/compose.yaml\n".write(
            to: workdir.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        try """
        services:
          redis:
            image: redis:7-alpine
        """.write(to: workdir.appendingPathComponent("shared/compose.yaml"), atomically: true, encoding: .utf8)

        try """
        include:
          - ${INCLUDE_FILE}
        services:
          web:
            image: nginx:alpine
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)

        XCTAssertEqual(project.services.map(\.name), ["redis", "web"])
    }

    func testIncludedFileUsesItsOwnDotEnvForInterpolationBeforeMerge() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try FileManager.default.createDirectory(
            at: workdir.appendingPathComponent("shared"),
            withIntermediateDirectories: true
        )

        try "IMAGE=nginx:alpine\n".write(to: workdir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "IMAGE=redis:7-alpine\n".write(to: workdir.appendingPathComponent("shared/.env"), atomically: true, encoding: .utf8)

        try """
        services:
          redis:
            image: ${IMAGE:?shared image required}
        """.write(to: workdir.appendingPathComponent("shared/compose.yaml"), atomically: true, encoding: .utf8)

        try """
        include:
          - shared/compose.yaml
        services:
          web:
            image: ${IMAGE:?root image required}
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)
        let redis = try XCTUnwrap(project.services.first { $0.name == "redis" })
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(redis.image, "redis:7-alpine")
        XCTAssertEqual(web.image, "nginx:alpine")
    }

    func testInterpolationPreservesAndCoercesNonStringScalars() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        EXTERNAL=true
        INTERNAL=false
        CPUS=2
        """.write(to: workdir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        try """
        services:
          web:
            image: nginx
            cpus: ${CPUS}
            networks:
              - back
        networks:
          back:
            external: ${EXTERNAL}
            internal: ${INTERNAL}
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.cpus, "2")
        XCTAssertEqual(project.networks["back"]?.external, true)
        XCTAssertEqual(project.networks["back"]?.internalOnly, false)
    }

    func testLoaderFailsForRequiredInterpolationVariables() {
        let yaml = """
        services:
          web:
            image: ${IMAGE:?image is required}
        """

        XCTAssertThrowsError(try ComposeLoader().load(yaml: yaml, sourcePath: "/tmp/demo/compose.yaml")) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Required environment variable IMAGE is not set: image is required"
            )
        }
    }

    func testLoadsOrderedComposeFilesWithOverrideMerge() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        name: demo
        services:
          web:
            image: nginx:alpine
            command: ["nginx", "-g", "daemon off;"]
            environment:
              LOG_LEVEL: info
              SHARED: base
            ports:
              - "8080:80"
            depends_on:
              - db
          db:
            image: postgres:16
        networks:
          front: {}
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          web:
            command: ["nginx", "-T"]
            environment:
              SHARED: override
              DEBUG: "1"
            ports:
              - "8443:443"
          worker:
            image: busybox
        volumes:
          cache: {}
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(
            from: [basePath.path, overridePath.path],
            activeProfiles: []
        )

        let web = try XCTUnwrap(project.services.first { $0.name == "web" })
        XCTAssertEqual(project.services.map(\.name), ["db", "web", "worker"])
        XCTAssertEqual(web.command, ["nginx", "-T"])
        XCTAssertEqual(web.environment["LOG_LEVEL"], "info")
        XCTAssertEqual(web.environment["SHARED"], "override")
        XCTAssertEqual(web.environment["DEBUG"], "1")
        XCTAssertEqual(web.ports, ["8080:80", "8443:443"])
        XCTAssertEqual(web.dependsOn, ["db"])
        XCTAssertEqual(project.networks["front"]?.name, "front")
        XCTAssertEqual(project.volumes["cache"]?.name, "cache")
    }

    func testMergesMixedDependsOnFormsAcrossOrderedComposeFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          api:
            image: backend
          db:
            image: postgres:16
          web:
            image: nginx:alpine
            depends_on:
              db:
                condition: service_healthy
                restart: true
                required: false
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          web:
            depends_on:
              - api
              - db
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(
            from: [basePath.path, overridePath.path],
            activeProfiles: []
        )
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.dependsOn, ["api", "db"])
        XCTAssertEqual(web.dependsOnMetadata["api"], ComposeServiceDependencyMetadata())
        XCTAssertEqual(web.dependsOnMetadata["db"], ComposeServiceDependencyMetadata(
            condition: .serviceHealthy,
            restart: true,
            required: false
        ))
    }

    func testMergesMixedExpandedMappingFormsAcrossOrderedComposeFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: nginx:alpine
            environment:
              - LOG_LEVEL=info
              - KEEP
            labels:
              - com.example.role=web
            annotations:
              com.example.owner: base
            sysctls:
              - net.core.somaxconn=1024
            extra_hosts:
              - db.local=10.0.0.5
              - cache.local=10.0.0.8
            build:
              context: .
              args:
                - BASE=1
              labels:
                com.example.build: base
              extra_hosts:
                - build.local=10.0.0.7
                - builder.local=10.0.0.10
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          web:
            environment:
              LOG_LEVEL: debug
              DEBUG: "1"
            labels:
              com.example.role: api
              com.example.tier: edge
            annotations:
              - com.example.owner=override
              - com.example.note=enabled
            sysctls:
              net.ipv4.ip_forward: "1"
            extra_hosts:
              db.local: 10.0.0.6
              cache.local: 10.0.0.8
            build:
              args:
                BASE: 2
                EXTRA: true
              labels:
                - com.example.build=override
                - com.example.release
              extra_hosts:
                build.local: 10.0.0.9
                builder.local: 10.0.0.10
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(
            from: [basePath.path, overridePath.path],
            activeProfiles: []
        )
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })
        let build = try XCTUnwrap(web.build)

        XCTAssertEqual(web.environment, [
            "DEBUG": "1",
            "KEEP": "",
            "LOG_LEVEL": "debug"
        ])
        XCTAssertEqual(web.labels, [
            "com.example.role=api",
            "com.example.tier=edge"
        ])
        XCTAssertEqual(web.annotations, [
            "com.example.note=enabled",
            "com.example.owner=override"
        ])
        XCTAssertEqual(web.sysctls, [
            "net.core.somaxconn": "1024",
            "net.ipv4.ip_forward": "1"
        ])
        XCTAssertEqual(web.extraHosts, [
            "db.local=10.0.0.5",
            "cache.local=10.0.0.8",
            "db.local=10.0.0.6"
        ])
        XCTAssertEqual(build.args, ["BASE=2", "EXTRA=true"])
        XCTAssertEqual(build.labels, [
            "com.example.build=override",
            "com.example.release="
        ])
        XCTAssertEqual(build.extraHosts, [
            "build.local=10.0.0.7",
            "builder.local=10.0.0.10",
            "build.local=10.0.0.9"
        ])
    }

    func testResetTagClearsSequenceAndRemovesNestedMappingEntry() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: nginx:alpine
            environment:
              LOG_LEVEL: info
              DEBUG: "1"
            ports:
              - "8080:80"
              - "8443:443"
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          web:
            environment:
              DEBUG: !reset null
            ports: !reset []
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: [basePath.path, overridePath.path])
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.environment, ["LOG_LEVEL": "info"])
        XCTAssertEqual(web.ports, [])
    }

    func testOverrideTagReplacesSequenceInsteadOfAppending() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: nginx:alpine
            ports:
              - "8080:80"
              - "9000:90"
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          web:
            ports: !override
              - "8443:443"
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: [basePath.path, overridePath.path])
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.ports, ["8443:443"])
    }

    func testOverrideTagReplacesWholeMappingInsteadOfMerging() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: nginx:alpine
            environment:
              LOG_LEVEL: info
              DEBUG: "1"
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          web:
            environment: !override
              NEW_VALUE: enabled
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: [basePath.path, overridePath.path])
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.environment, ["NEW_VALUE": "enabled"])
    }

    func testMergeTagsInSingleFileAreNormalized() throws {
        let yaml = """
        services:
          web:
            image: nginx:alpine
            environment: !override
              LOG_LEVEL: info
            ports: !reset []
        """

        let project = try ComposeLoader().load(yaml: yaml, sourcePath: "/tmp/demo/compose.yaml")
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.environment, ["LOG_LEVEL": "info"])
        XCTAssertEqual(web.ports, [])
    }

    func testDefaultDiscoveryLoadsComposeOverrideFile() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        name: demo
        services:
          web:
            image: nginx:alpine
            ports:
              - "8080:80"
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        try """
        services:
          web:
            ports:
              - "8443:443"
        """.write(to: workdir.appendingPathComponent("compose.override.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)

        XCTAssertEqual(project.services.first?.ports, ["8080:80", "8443:443"])
    }

    func testUniquePortsAndVolumesOverrideByComposeMergeKey() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: nginx:alpine
            ports:
              - "8080:80"
              - "127.0.0.1:9000:90/udp"
            volumes:
              - cache:/cache
              - ./config:/etc/config:ro
        volumes:
          cache: {}
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          web:
            ports:
              - "8081:80"
              - "9001:91"
            volumes:
              - other-cache:/cache
              - logs:/var/log/app
        volumes:
          other-cache: {}
          logs: {}
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: [basePath.path, overridePath.path])
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.ports, ["8080:80", "127.0.0.1:9000:90/udp", "8081:80", "9001:91"])
        XCTAssertEqual(web.volumes, ["other-cache:/cache", "./config:/etc/config:ro", "logs:/var/log/app"])
    }

    func testLongPortAndVolumeSyntaxCanOverrideShortSyntax() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: nginx:alpine
            ports:
              - "8080:80"
            volumes:
              - cache:/cache
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          web:
            ports:
              - target: 80
                published: 8081
                protocol: tcp
            volumes:
              - type: volume
                source: other-cache
                target: /cache
                read_only: true
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: [basePath.path, overridePath.path])
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.ports, ["8080:80", "8081:80"])
        XCTAssertEqual(web.volumes, ["other-cache:/cache:ro"])
    }

    func testPortsOverrideOnlyWhenFullComposeUniqueKeyMatches() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let basePath = workdir.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: nginx:alpine
            ports:
              - target: 80
                published: 8080
        """.write(to: basePath, atomically: true, encoding: .utf8)

        let overridePath = workdir.appendingPathComponent("compose.override.yaml")
        try """
        services:
          web:
            ports:
              - target: 80
                published: 8080
                protocol: tcp
        """.write(to: overridePath, atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: [basePath.path, overridePath.path])
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.ports, ["8080:80"])
    }

    func testLoadsShortSyntaxIncludeIntoCurrentProject() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try FileManager.default.createDirectory(
            at: workdir.appendingPathComponent("shared"),
            withIntermediateDirectories: true
        )

        try """
        services:
          redis:
            image: redis:7-alpine
        volumes:
          redis-data: {}
        """.write(to: workdir.appendingPathComponent("shared/compose.yaml"), atomically: true, encoding: .utf8)

        try """
        name: app
        include:
          - shared/compose.yaml
        services:
          web:
            image: nginx:alpine
            depends_on:
              - redis
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)

        XCTAssertEqual(project.services.map(\.name), ["redis", "web"])
        XCTAssertEqual(project.volumes["redis-data"]?.name, "redis-data")
        XCTAssertTrue(project.diagnostics.isEmpty)
    }

    func testLoadsServiceExtraHostsAsListOrMapping() throws {
        let yaml = """
        services:
          api:
            image: example/api:dev
            extra_hosts:
              db.local: 10.0.0.5
              cache.local: 10.0.0.6
          worker:
            image: example/worker:dev
            extra_hosts:
              - queue.local=10.0.0.7
              - metrics.local:10.0.0.8
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let api = try XCTUnwrap(project.services.first { $0.name == "api" })
        let worker = try XCTUnwrap(project.services.first { $0.name == "worker" })

        XCTAssertEqual(api.extraHosts, ["cache.local=10.0.0.6", "db.local=10.0.0.5"])
        XCTAssertEqual(worker.extraHosts, ["queue.local=10.0.0.7", "metrics.local:10.0.0.8"])
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.api.extra_hosts" })
    }

    func testLoadsServiceExposeAsInternalPorts() throws {
        let yaml = """
        services:
          web:
            image: nginx
            expose:
              - "3000"
              - "8080-8085/tcp"
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.exposedPorts, ["3000", "8080-8085/tcp"])
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.expose" })
    }

    func testLoadsServicePrivilegedMode() throws {
        let yaml = """
        services:
          web:
            image: nginx
            privileged: true
          worker:
            image: alpine
            privileged: false
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })
        let worker = try XCTUnwrap(project.services.first { $0.name == "worker" })

        XCTAssertEqual(web.privileged, true)
        XCTAssertEqual(worker.privileged, false)
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.privileged" })
    }

    func testInvalidServicePrivilegedValueProducesDiagnostic() throws {
        let yaml = """
        services:
          web:
            image: nginx
            privileged: maybe
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertNil(web.privileged)
        XCTAssertTrue(project.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.privileged"
            && $0.message == "Expected a boolean value."
        })
    }

    func testLoadsServiceSecurityOptions() throws {
        let yaml = """
        services:
          web:
            image: nginx
            security_opt:
              - label:user:USER
              - label:role:ROLE
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.securityOptions, ["label:user:USER", "label:role:ROLE"])
        XCTAssertFalse(project.diagnostics.contains { $0.path == "services.web.security_opt" })
    }

    func testMergesServiceSecurityOptionsWithoutDuplicates() throws {
        let project = try ComposeLoader().load(
            from: [
                ComposeSource(path: "compose.yaml", yaml: """
                services:
                  web:
                    image: nginx
                    security_opt:
                      - label:user:USER
                      - label:role:ROLE
                """),
                ComposeSource(path: "compose.override.yaml", yaml: """
                services:
                  web:
                    security_opt:
                      - label:role:ROLE
                      - no-new-privileges:true
                """)
            ],
            workingDirectory: "/tmp/container-compose-security-opt"
        )
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.securityOptions, ["label:user:USER", "label:role:ROLE", "no-new-privileges:true"])
    }

    func testMergesServiceExposeEntriesWithoutDuplicates() throws {
        let project = try ComposeLoader().load(
            from: [
                ComposeSource(path: "compose.yaml", yaml: """
                services:
                  web:
                    image: nginx
                    expose:
                      - "3000"
                      - "8080/tcp"
                """),
                ComposeSource(path: "compose.override.yaml", yaml: """
                services:
                  web:
                    expose:
                      - "8080/tcp"
                      - "9090"
                """)
            ],
            workingDirectory: "/tmp/container-compose-expose"
        )
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })

        XCTAssertEqual(web.exposedPorts, ["3000", "8080/tcp", "9090"])
    }

    func testShortSyntaxIncludeCanLoadRemoteHttpComposeWhenEnabled() throws {
        let loader = makeRemoteLoader(fixtures: [
            "https://example.test/shared/compose.yaml": """
            services:
              redis:
                image: redis:7-alpine
            volumes:
              redis-data: {}
            """
        ])

        let project = try loader.load(
            yaml: """
            include:
              - https://example.test/shared/compose.yaml
            services:
              web:
                image: nginx:alpine
                depends_on:
                  - redis
            """,
            sourcePath: "/tmp/demo/compose.yaml"
        )

        XCTAssertEqual(project.services.map(\.name), ["redis", "web"])
        XCTAssertEqual(project.volumes["redis-data"]?.name, "redis-data")
        XCTAssertTrue(project.diagnostics.isEmpty)
    }

    func testRemoteIncludeResolverCanReturnCacheProvenance() throws {
        let remoteYAML = """
        services:
          redis:
            image: redis:7-alpine
        """
        let loader = ComposeLoader(allowRemoteIncludes: true) { request in
            XCTAssertEqual(request.sanitizedURL, "https://example.test/shared/compose.yaml")
            XCTAssertEqual(request.includedFrom, "/tmp/demo/compose.yaml")
            XCTAssertEqual(request.includeStack, ["/tmp/demo/compose.yaml"])
            return ComposeLoader.RemoteIncludeResponse(
                yaml: remoteYAML,
                cacheKey: "sha256:shared-compose",
                cacheStatus: .hit,
                source: "container-desktop-cache"
            )
        }

        let project = try loader.load(
            yaml: """
            include:
              - https://example.test/shared/compose.yaml
            services:
              web:
                image: nginx:alpine
            """,
            sourcePath: "/tmp/demo/compose.yaml"
        )

        XCTAssertEqual(project.services.map(\.name), ["redis", "web"])
        XCTAssertEqual(project.remoteIncludes, [
            ComposeRemoteInclude(
                url: "https://example.test/shared/compose.yaml",
                cacheKey: "sha256:shared-compose",
                cacheStatus: .hit,
                source: "container-desktop-cache",
                contentLength: remoteYAML.utf8.count
            )
        ])
    }

    func testNestedRemoteIncludeResolverReceivesParentAndStack() throws {
        let recorder = RemoteIncludeRequestRecorder()
        let loader = ComposeLoader(allowRemoteIncludes: true) { request in
            recorder.requests.append(request)
            switch request.url.absoluteString {
            case "https://example.test/includes/base/compose.yaml":
                return ComposeLoader.RemoteIncludeResponse(yaml: """
                include:
                  - nested.yaml
                services:
                  redis:
                    image: redis:7-alpine
                """, cacheStatus: .miss, source: "network")
            case "https://example.test/includes/base/nested.yaml":
                return ComposeLoader.RemoteIncludeResponse(yaml: """
                services:
                  metrics:
                    image: prom/prometheus
                """, cacheStatus: .refreshed, source: "network")
            default:
                throw ComposeLoadError.fileNotFound([request.url.absoluteString])
            }
        }

        let project = try loader.load(
            yaml: """
            include:
              - https://example.test/includes/base/compose.yaml
            services:
              web:
                image: nginx:alpine
            """,
            sourcePath: "/tmp/demo/compose.yaml"
        )

        XCTAssertEqual(project.services.map(\.name), ["metrics", "redis", "web"])
        XCTAssertEqual(recorder.requests.map(\.sanitizedURL), [
            "https://example.test/includes/base/compose.yaml",
            "https://example.test/includes/base/nested.yaml"
        ])
        XCTAssertEqual(recorder.requests[0].includedFrom, "/tmp/demo/compose.yaml")
        XCTAssertEqual(recorder.requests[0].includeStack, ["/tmp/demo/compose.yaml"])
        XCTAssertEqual(recorder.requests[1].includedFrom, "https://example.test/includes/base/compose.yaml")
        XCTAssertEqual(recorder.requests[1].includeStack, [
            "/tmp/demo/compose.yaml",
            "https://example.test/includes/base/compose.yaml"
        ])
        XCTAssertEqual(project.remoteIncludes.map(\.cacheStatus), [.miss, .refreshed])
    }

    func testRemoteIncludeRequiresExplicitOptIn() throws {
        XCTAssertThrowsError(try ComposeLoader().load(
            yaml: """
            include:
              - https://example.test/shared/compose.yaml
            services:
              web:
                image: nginx:alpine
            """,
            sourcePath: "/tmp/demo/compose.yaml"
        )) { error in
            guard case ComposeLoadError.remoteIncludeDisabled(let url) = error else {
                return XCTFail("Expected remote include disabled error, got \(error).")
            }
            XCTAssertEqual(url, "https://example.test/shared/compose.yaml")
        }
    }

    func testRemoteIncludeFetchFailureSanitizesURL() throws {
        let loader = ComposeLoader(allowRemoteIncludes: true) { _ in
            throw ComposeLoadError.fileNotFound(["fixture"])
        }

        XCTAssertThrowsError(try loader.load(
            yaml: """
            include:
              - https://user:secret@example.test/shared/compose.yaml?token=abc#fragment
            services:
              web:
                image: nginx:alpine
            """,
            sourcePath: "/tmp/demo/compose.yaml"
        )) { error in
            guard case ComposeLoadError.remoteIncludeFetchFailed(let url, _) = error else {
                return XCTFail("Expected remote include fetch failure, got \(error).")
            }
            XCTAssertEqual(url, "https://example.test/shared/compose.yaml")
        }
    }

    func testNestedRemoteIncludeResolvesRelativeToRemoteParentURL() throws {
        let loader = makeRemoteLoader(fixtures: [
            "https://example.test/includes/base/compose.yaml": """
            include:
              - nested.yaml
            services:
              redis:
                image: redis:7-alpine
            """,
            "https://example.test/includes/base/nested.yaml": """
            services:
              metrics:
                image: prom/prometheus
            """
        ])

        let project = try loader.load(
            yaml: """
            include:
              - https://example.test/includes/base/compose.yaml
            services:
              web:
                image: nginx:alpine
            """,
            sourcePath: "/tmp/demo/compose.yaml"
        )

        XCTAssertEqual(project.services.map(\.name), ["metrics", "redis", "web"])
    }

    func testRemoteIncludeEnvFileIsIgnoredWithWarning() throws {
        let loader = makeRemoteLoader(fixtures: [
            "https://example.test/shared/compose.yaml": """
            services:
              redis:
                image: ${IMAGE:-redis:fallback}
            """
        ])

        let project = try loader.load(
            yaml: """
            include:
              - path: https://example.test/shared/compose.yaml
                env_file: defaults.env
            services:
              web:
                image: nginx:alpine
            """,
            sourcePath: "/tmp/demo/compose.yaml"
        )
        let redis = try XCTUnwrap(project.services.first { $0.name == "redis" })

        XCTAssertEqual(redis.image, "redis:fallback")
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "include.env_file" && $0.message == "Remote include env_file is not supported yet; process environment still applies."
        })
    }

    func testYamlLoaderResolvesIncludesRelativeToSourcePath() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          redis:
            image: redis:7-alpine
        """.write(to: workdir.appendingPathComponent("shared.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(
            yaml: """
            include:
              - shared.yaml
            services:
              web:
                image: nginx:alpine
            """,
            sourcePath: workdir.appendingPathComponent("compose.yaml").path
        )

        XCTAssertEqual(project.services.map(\.name), ["redis", "web"])
    }

    func testIncludeAppliesRecursively() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try FileManager.default.createDirectory(
            at: workdir.appendingPathComponent("shared/deeper"),
            withIntermediateDirectories: true
        )

        try """
        services:
          metrics:
            image: prom/prometheus
        """.write(to: workdir.appendingPathComponent("shared/deeper/compose.yaml"), atomically: true, encoding: .utf8)

        try """
        include:
          - deeper/compose.yaml
        services:
          redis:
            image: redis:7-alpine
        """.write(to: workdir.appendingPathComponent("shared/compose.yaml"), atomically: true, encoding: .utf8)

        try """
        include:
          - shared/compose.yaml
        services:
          web:
            image: nginx:alpine
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)

        XCTAssertEqual(project.services.map(\.name), ["metrics", "redis", "web"])
    }

    func testIncludeConflictsKeepCurrentProjectAndWarn() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: included
        """.write(to: workdir.appendingPathComponent("included.yaml"), atomically: true, encoding: .utf8)

        try """
        include:
          - included.yaml
        services:
          web:
            image: current
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)

        XCTAssertEqual(project.services.first?.image, "current")
        XCTAssertEqual(project.diagnostics.first?.severity, .warning)
        XCTAssertEqual(project.diagnostics.first?.path, "services.web")
    }

    func testLongSyntaxIncludeCanMergeMultipleFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try FileManager.default.createDirectory(
            at: workdir.appendingPathComponent("shared"),
            withIntermediateDirectories: true
        )

        try """
        services:
          redis:
            image: redis:7-alpine
            ports:
              - "6379:6379"
        """.write(to: workdir.appendingPathComponent("shared/base.yaml"), atomically: true, encoding: .utf8)

        try """
        services:
          redis:
            ports:
              - "6380:6379"
        """.write(to: workdir.appendingPathComponent("shared/override.yaml"), atomically: true, encoding: .utf8)

        try """
        include:
          - path:
              - base.yaml
              - override.yaml
            project_directory: shared
        services:
          web:
            image: nginx:alpine
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)
        let redis = try XCTUnwrap(project.services.first { $0.name == "redis" })

        XCTAssertEqual(redis.ports, ["6379:6379", "6380:6379"])
    }

    func testLongSyntaxIncludeUsesEnvFileForInterpolationDefaults() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try FileManager.default.createDirectory(
            at: workdir.appendingPathComponent("shared/env"),
            withIntermediateDirectories: true
        )

        try """
        IMAGE=redis:7-alpine
        """.write(to: workdir.appendingPathComponent("shared/env/defaults.env"), atomically: true, encoding: .utf8)

        try """
        services:
          redis:
            image: ${IMAGE:?image required}
        """.write(to: workdir.appendingPathComponent("shared/compose.yaml"), atomically: true, encoding: .utf8)

        try """
        include:
          - path: compose.yaml
            project_directory: shared
            env_file: env/defaults.env
        services:
          web:
            image: nginx:alpine
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)
        let redis = try XCTUnwrap(project.services.first { $0.name == "redis" })

        XCTAssertEqual(redis.image, "redis:7-alpine")
        XCTAssertFalse(project.diagnostics.contains { $0.path == "include.env_file" })
    }

    func testLongSyntaxIncludeEnvFileListUsesLaterValues() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try FileManager.default.createDirectory(
            at: workdir.appendingPathComponent("shared"),
            withIntermediateDirectories: true
        )

        try "IMAGE=redis:6\nTAG=base\n".write(
            to: workdir.appendingPathComponent("shared/defaults.env"),
            atomically: true,
            encoding: .utf8
        )
        try "IMAGE=redis:7-alpine\n".write(
            to: workdir.appendingPathComponent("shared/dev.env"),
            atomically: true,
            encoding: .utf8
        )

        try """
        services:
          redis:
            image: ${IMAGE}
            environment:
              TAG: ${TAG}
        """.write(to: workdir.appendingPathComponent("shared/compose.yaml"), atomically: true, encoding: .utf8)

        try """
        include:
          - path: compose.yaml
            project_directory: shared
            env_file:
              - defaults.env
              - dev.env
        services:
          web:
            image: nginx:alpine
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)
        let redis = try XCTUnwrap(project.services.first { $0.name == "redis" })

        XCTAssertEqual(redis.image, "redis:7-alpine")
        XCTAssertEqual(redis.environment["TAG"], "base")
    }

    func testLongSyntaxIncludeEnvFileDefaultsCanBeOverriddenByProcessEnvironment() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try FileManager.default.createDirectory(
            at: workdir.appendingPathComponent("shared"),
            withIntermediateDirectories: true
        )

        try "IMAGE=redis:7-alpine\n".write(
            to: workdir.appendingPathComponent("shared/defaults.env"),
            atomically: true,
            encoding: .utf8
        )

        try """
        services:
          redis:
            image: ${IMAGE}
        """.write(to: workdir.appendingPathComponent("shared/compose.yaml"), atomically: true, encoding: .utf8)

        try """
        include:
          - path: compose.yaml
            project_directory: shared
            env_file: defaults.env
        services:
          web:
            image: nginx:alpine
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader(environment: ["IMAGE": "redis:process"]).load(workingDirectory: workdir.path)
        let redis = try XCTUnwrap(project.services.first { $0.name == "redis" })

        XCTAssertEqual(redis.image, "redis:process")
    }

    func testLongSyntaxIncludeEnvFileWarningsForMalformedItems() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try FileManager.default.createDirectory(
            at: workdir.appendingPathComponent("shared"),
            withIntermediateDirectories: true
        )

        try "IMAGE=redis:7-alpine\n".write(
            to: workdir.appendingPathComponent("shared/defaults.env"),
            atomically: true,
            encoding: .utf8
        )

        try """
        services:
          redis:
            image: ${IMAGE}
        """.write(to: workdir.appendingPathComponent("shared/compose.yaml"), atomically: true, encoding: .utf8)

        try """
        include:
          - path: compose.yaml
            project_directory: shared
            env_file:
              - defaults.env
              - bad: true
        services:
          web:
            image: nginx:alpine
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)

        XCTAssertEqual(project.services.map(\.name), ["redis", "web"])
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "include.env_file" && $0.message == "Unsupported include env_file list item was ignored."
        })
    }

    func testLongSyntaxIncludeEnvFileWarnsWhenFileIsMissing() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try FileManager.default.createDirectory(
            at: workdir.appendingPathComponent("shared"),
            withIntermediateDirectories: true
        )

        try """
        services:
          redis:
            image: redis:${TAG:-latest}
        """.write(to: workdir.appendingPathComponent("shared/compose.yaml"), atomically: true, encoding: .utf8)

        try """
        include:
          - path: compose.yaml
            project_directory: shared
            env_file: missing.env
        services:
          web:
            image: nginx:alpine
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)

        XCTAssertEqual(project.services.map(\.name), ["redis", "web"])
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "include.env_file" && $0.message.contains("missing.env")
        })
    }

    func testIncludeInOverrideFileResolvesRelativeToOverrideDirectory() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try FileManager.default.createDirectory(
            at: workdir.appendingPathComponent("overrides"),
            withIntermediateDirectories: true
        )

        try """
        services:
          web:
            image: nginx:alpine
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        try """
        include:
          - shared.yaml
        services:
          worker:
            image: busybox
        """.write(to: workdir.appendingPathComponent("overrides/compose.override.yaml"), atomically: true, encoding: .utf8)

        try """
        services:
          redis:
            image: redis:7-alpine
        """.write(to: workdir.appendingPathComponent("overrides/shared.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(from: [
            workdir.appendingPathComponent("compose.yaml").path,
            workdir.appendingPathComponent("overrides/compose.override.yaml").path
        ])

        XCTAssertEqual(project.services.map(\.name), ["redis", "web", "worker"])
    }

    func testNestedIncludeFromNonFirstIncludedFileUsesThatFileDirectory() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try FileManager.default.createDirectory(
            at: workdir.appendingPathComponent("shared/extra"),
            withIntermediateDirectories: true
        )

        try """
        services:
          redis:
            image: redis:7-alpine
        """.write(to: workdir.appendingPathComponent("shared/base.yaml"), atomically: true, encoding: .utf8)

        try """
        include:
          - nested.yaml
        services:
          worker:
            image: busybox
        """.write(to: workdir.appendingPathComponent("shared/extra/override.yaml"), atomically: true, encoding: .utf8)

        try """
        services:
          metrics:
            image: prom/prometheus
        """.write(to: workdir.appendingPathComponent("shared/extra/nested.yaml"), atomically: true, encoding: .utf8)

        try """
        include:
          - path:
              - base.yaml
              - extra/override.yaml
            project_directory: shared
        services:
          web:
            image: nginx:alpine
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)

        XCTAssertEqual(project.services.map(\.name), ["metrics", "redis", "web", "worker"])
    }

    func testRecursiveIncludeThrowsLoadError() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        include:
          - b.yaml
        services:
          web:
            image: nginx:alpine
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        try """
        include:
          - compose.yaml
        services:
          worker:
            image: busybox
        """.write(to: workdir.appendingPathComponent("b.yaml"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ComposeLoader().load(workingDirectory: workdir.path)) { error in
            guard case ComposeLoadError.recursiveInclude = error else {
                return XCTFail("Expected recursive include error, got \(error).")
            }
        }
    }

    func testLongSyntaxIncludeWarnsForMalformedPathListItems() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          redis:
            image: redis:7-alpine
        """.write(to: workdir.appendingPathComponent("valid.yaml"), atomically: true, encoding: .utf8)

        try """
        include:
          - path:
              - valid.yaml
              - bad: true
        services:
          web:
            image: nginx:alpine
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = try ComposeLoader().load(workingDirectory: workdir.path)

        XCTAssertEqual(project.services.map(\.name), ["redis", "web"])
        XCTAssertTrue(project.diagnostics.contains {
            $0.path == "include.path" && $0.message == "Unsupported include path list item was ignored."
        })
    }
}

private final class RemoteIncludeRequestRecorder: @unchecked Sendable {
    var requests: [ComposeLoader.RemoteIncludeRequest] = []
}
