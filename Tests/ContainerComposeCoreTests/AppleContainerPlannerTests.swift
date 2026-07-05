import XCTest
@testable import ContainerComposeCore

final class AppleContainerPlannerTests: XCTestCase {
    func testPlansDependenciesBeforeDependents() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", ports: ["8080:80"], networks: ["front"], dependsOn: ["db"]),
                ComposeService(name: "db", image: "postgres", environment: ["POSTGRES_PASSWORD": "secret"], volumes: ["db-data:/var/lib/postgresql/data"])
            ],
            networks: ["front": ComposeNetwork(name: "front")],
            volumes: ["db-data": ComposeVolume(name: "db-data")],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planUp(project: project)
        let runCommands = commands.filter { $0.action == .runService }

        XCTAssertEqual(runCommands.map(\.service), ["db", "web"])
        XCTAssertTrue(runCommands[0].arguments.contains("demo_db_1"))
        XCTAssertTrue(runCommands[1].arguments.contains("8080:80"))
        XCTAssertTrue(runCommands[1].arguments.contains("demo_front"))
    }

    func testServiceNetworkAttachmentOptionsEmitPlannerDiagnostic() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    networks: ["front"],
                    networkAttachments: [
                        ComposeServiceNetworkAttachment(
                            name: "front",
                            aliases: ["web.local"],
                            interfaceName: "eth0",
                            ipv4Address: "172.16.238.10"
                        )
                    ]
                )
            ],
            networks: ["front": ComposeNetwork(name: "front")],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertTrue(command.arguments.contains("demo_front"))
        XCTAssertFalse(command.arguments.contains("web.local"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.networks.front"
            && $0.message.contains("not mapped")
        })
    }

    func testTopLevelNetworkOptionsEmitPlannerDiagnostics() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", networks: ["front"])
            ],
            networks: [
                "front": ComposeNetwork(
                    name: "front",
                    customName: "shared_front",
                    internalOnly: true,
                    attachable: true,
                    driver: "bridge",
                    driverOptions: ["com.example.mode": "fast"],
                    enableIPv6: true,
                    ipam: ComposeNetworkIPAM(config: [
                        ComposeNetworkIPAMConfig(subnet: "172.28.0.0/16")
                    ]),
                    labels: ["com.example.scope=dev"]
                )
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planUp(project: project)
        let createNetwork = try XCTUnwrap(commands.first { $0.action == .createNetwork })
        let runService = try XCTUnwrap(commands.first { $0.action == .runService })

        XCTAssertEqual(createNetwork.arguments, [
            "network",
            "create",
            "--internal",
            "--label",
            "com.example.scope=dev",
            "shared_front"
        ])
        XCTAssertTrue(createNetwork.diagnostics.contains {
            $0.path == "networks.front"
            && $0.message.contains("not fully mapped")
        })
        XCTAssertTrue(runService.arguments.contains("shared_front"))
        XCTAssertTrue(runService.diagnostics.contains {
            $0.path == "networks.front"
            && $0.message.contains("not fully mapped")
        })
    }

    func testExternalNetworkLookupNameIsUsedForServiceAttachment() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", networks: ["outside"])
            ],
            networks: [
                "outside": ComposeNetwork(name: "outside", external: true, externalName: "platform_net")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planUp(project: project)
        let run = try XCTUnwrap(commands.first { $0.action == .runService })

        XCTAssertFalse(commands.contains { $0.action == .createNetwork })
        XCTAssertTrue(run.arguments.contains("platform_net"))
    }

    func testPlanUpCreatesAndAttachesImplicitDefaultNetwork() throws {
        let yaml = """
        name: demo
        services:
          web:
            image: nginx
        """
        let project = try ComposeLoader().load(yaml: yaml)

        let commands = AppleContainerPlanner().planUp(project: project)
        let createNetwork = try XCTUnwrap(commands.first { $0.action == .createNetwork })
        let run = try XCTUnwrap(commands.first { $0.action == .runService })

        XCTAssertEqual(createNetwork.arguments, ["network", "create", "demo_default"])
        XCTAssertTrue(run.arguments.contains("demo_default"))
    }

    func testImplicitDefaultNetworkUsesCustomPlatformNameInPlan() throws {
        let yaml = """
        name: demo
        services:
          web:
            image: nginx
        networks:
          default:
            name: shared_default
        """
        let project = try ComposeLoader().load(yaml: yaml)

        let commands = AppleContainerPlanner().planUp(project: project)
        let createNetwork = try XCTUnwrap(commands.first { $0.action == .createNetwork })
        let run = try XCTUnwrap(commands.first { $0.action == .runService })

        XCTAssertEqual(createNetwork.arguments, ["network", "create", "shared_default"])
        XCTAssertTrue(run.arguments.contains("shared_default"))
    }

    func testTopLevelVolumeOptionsEmitPlannerDiagnostics() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", volumes: ["data:/data", "external-data:/external"])
            ],
            volumes: [
                "data": ComposeVolume(
                    name: "data",
                    customName: "shared_data",
                    driver: "local",
                    driverOptions: ["type": "nfs"],
                    labels: ["com.example.scope=dev"]
                ),
                "external-data": ComposeVolume(
                    name: "external-data",
                    external: true,
                    externalName: "existing_data"
                )
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planUp(project: project)
        let command = try XCTUnwrap(commands.first { $0.action == .createVolume })
        let run = try XCTUnwrap(commands.first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "volume",
            "create",
            "--label",
            "com.example.scope=dev",
            "shared_data"
        ])
        XCTAssertTrue(command.diagnostics.contains {
            $0.path == "volumes.data"
            && $0.message.contains("not fully mapped")
        })
        XCTAssertTrue(run.arguments.contains("shared_data:/data"))
        XCTAssertTrue(run.arguments.contains("existing_data:/external"))
    }

    func testMissingImageProducesErrorDiagnostic() {
        let project = ComposeProject(
            name: "demo",
            services: [ComposeService(name: "web", image: nil)],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planUp(project: project)

        XCTAssertEqual(commands.first?.diagnostics.first?.severity, .error)
    }

    func testPlansBuildBeforeRunAndUsesGeneratedImageWhenImageIsMissing() throws {
        let workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-build-planner-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }
        let resolvedWorkdir = workdir.standardizedFileURL

        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: nil, build: ComposeBuild(context: "web"))
            ],
            sourcePath: workdir.appendingPathComponent("compose.yaml").path
        )

        let commands = AppleContainerPlanner().planUp(project: project)

        XCTAssertEqual(commands.map(\.action), [.buildService, .runService])
        XCTAssertEqual(commands[0].arguments, [
            "build",
            "--tag",
            "demo_web:latest",
            resolvedWorkdir.appendingPathComponent("web").path
        ])
        XCTAssertEqual(commands[1].arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "demo_web:latest"
        ])

        let plan = AppleContainerPlan(project: project, operation: "up", commands: commands)
        XCTAssertEqual(plan.executionGraph?.edges, [
            AppleContainerExecutionEdge(fromCommandIndex: 0, toCommandIndex: 1, reason: "build")
        ])
        XCTAssertEqual(plan.executionGraph?.nodes[0].dependsOnCommandIndexes, [])
        XCTAssertEqual(plan.executionGraph?.nodes[1].dependsOnCommandIndexes, [0])
    }

    func testPlansCreateAsStoppedServiceContainersWithResources() throws {
        let workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-create-planner-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }

        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: nil,
                    build: ComposeBuild(context: "web"),
                    ports: ["8080:80"],
                    networks: ["front"],
                    dependsOn: ["db"]
                ),
                ComposeService(
                    name: "db",
                    image: "postgres",
                    volumes: ["db-data:/var/lib/postgresql/data"]
                )
            ],
            networks: ["front": ComposeNetwork(name: "front")],
            volumes: ["db-data": ComposeVolume(name: "db-data")],
            sourcePath: workdir.appendingPathComponent("compose.yaml").path
        )

        let commands = AppleContainerPlanner().planCreate(project: project, services: ["web"])

        XCTAssertEqual(commands.map(\.action), [.buildService, .createNetwork, .createVolume, .createService, .createService])
        XCTAssertEqual(commands.filter { $0.action == .createService }.map(\.service), ["db", "web"])
        XCTAssertEqual(commands[1].arguments, ["network", "create", "demo_front"])
        XCTAssertEqual(commands[2].arguments, ["volume", "create", "demo_db-data"])
        XCTAssertEqual(commands[3].arguments, [
            "create",
            "--name",
            "demo_db_1",
            "--volume",
            "demo_db-data:/var/lib/postgresql/data",
            "postgres"
        ])
        XCTAssertEqual(commands[4].arguments, [
            "create",
            "--name",
            "demo_web_1",
            "--publish",
            "8080:80",
            "--network",
            "demo_front",
            "demo_web:latest"
        ])

        let plan = AppleContainerPlan(project: project, operation: "create", commands: commands)
        XCTAssertEqual(plan.executionGraph?.nodes[4].dependsOnCommandIndexes, [0, 3])
    }

    func testPlansCreateCanSkipBuildCommands() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: nil, build: ComposeBuild(context: "."))
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planCreate(project: project, options: .init(noBuild: true))

        XCTAssertEqual(commands.map(\.action), [.createService])
        XCTAssertEqual(commands[0].arguments, [
            "create",
            "--name",
            "demo_web_1",
            "demo_web:latest"
        ])
    }

    func testPlansExplicitAlwaysPullPolicyBeforeRun() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx:latest", pullPolicy: "always", platform: "linux/arm64")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planUp(project: project)

        XCTAssertEqual(commands.map(\.action), [.pullImage, .runService])
        XCTAssertEqual(commands[0].arguments, [
            "image",
            "pull",
            "--platform",
            "linux/arm64",
            "nginx:latest"
        ])
        XCTAssertEqual(commands[1].arguments.suffix(1), ["nginx:latest"])

        let plan = AppleContainerPlan(project: project, operation: "up", commands: commands)
        XCTAssertEqual(plan.executionGraph?.edges, [
            AppleContainerExecutionEdge(fromCommandIndex: 0, toCommandIndex: 1, reason: "pull")
        ])
        XCTAssertEqual(plan.executionGraph?.nodes[1].dependsOnCommandIndexes, [0])
    }

    func testPlansPullForImageServicesAndSkipsBuildOnlyServices() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "api", image: "example/api:dev", platform: "linux/arm64"),
                ComposeService(name: "web", image: nil, build: ComposeBuild(context: "web"))
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planPull(project: project)

        XCTAssertEqual(commands, [
            PlannedCommand(
                action: .pullImage,
                service: "api",
                arguments: ["image", "pull", "--platform", "linux/arm64", "example/api:dev"]
            )
        ])
    }

    func testPlansPullForSelectedServicesOnly() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "api", image: "example/api:dev"),
                ComposeService(name: "web", image: "nginx")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planPull(project: project, services: ["web"])

        XCTAssertEqual(commands.map(\.service), ["web"])
        XCTAssertEqual(commands.first?.arguments, ["image", "pull", "nginx"])
    }

    func testPlansPushForImageServicesAndSkipsBuildOnlyServices() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "api", image: "example/api:dev", platform: "linux/arm64"),
                ComposeService(name: "web", image: nil, build: ComposeBuild(context: "web"))
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planPush(project: project)

        XCTAssertEqual(commands, [
            PlannedCommand(
                action: .pushImage,
                service: "api",
                arguments: ["image", "push", "--platform", "linux/arm64", "example/api:dev"]
            )
        ])
    }

    func testPlansPushForSelectedServiceDependenciesAndQuietMode() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "example/web:dev", dependsOn: ["api"]),
                ComposeService(name: "api", image: "example/api:dev")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planPush(
            project: project,
            services: ["web"],
            options: .init(includeDependencies: true, quiet: true)
        )

        XCTAssertEqual(commands.map(\.service), ["api", "web"])
        XCTAssertEqual(commands.map(\.arguments), [
            ["image", "push", "--progress", "none", "example/api:dev"],
            ["image", "push", "--progress", "none", "example/web:dev"]
        ])
    }

    func testPlansPushWithIgnoreFailuresDiagnostic() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "api", image: "example/api:dev")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planPush(
            project: project,
            options: .init(ignorePushFailures: true)
        )

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .pushImage)
        XCTAssertEqual(commands[0].diagnostics.first?.severity, .warning)
        XCTAssertEqual(commands[0].diagnostics.first?.path, "push.ignore_push_failures")
    }

    func testPlansImagesAsAppleContainerImageListWithScopingDiagnostic() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "api", image: "example/api:dev")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planImages(project: project)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .listImages)
        XCTAssertEqual(commands[0].arguments, ["image", "list"])
        XCTAssertEqual(commands[0].diagnostics.first?.severity, .warning)
        XCTAssertEqual(commands[0].diagnostics.first?.path, "images")
    }

    func testPlansImagesWithFormatQuietVerboseAndServiceDiagnostic() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "api", image: "example/api:dev")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planImages(
            project: project,
            services: ["api"],
            options: .init(format: "json", quiet: true, verbose: true)
        )

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].arguments, ["image", "list", "--format", "json", "--quiet", "--verbose"])
        XCTAssertTrue(commands[0].diagnostics.contains { $0.path == "images.services" })
    }

    func testPlansBuildForBuildServicesAndSkipsImageOnlyServices() throws {
        let workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-build-planner-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }

        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "api", image: "example/api:dev", build: ComposeBuild(context: "api")),
                ComposeService(name: "web", image: "nginx")
            ],
            sourcePath: workdir.appendingPathComponent("compose.yaml").path
        )

        let commands = AppleContainerPlanner().planBuild(project: project)

        XCTAssertEqual(commands.map(\.service), ["api"])
        XCTAssertEqual(commands.first?.arguments.prefix(3), ["build", "--tag", "example/api:dev"])
    }

    func testPlansBuildForSelectedServicesOnly() throws {
        let workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-build-planner-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }

        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "api", image: "example/api:dev", build: ComposeBuild(context: "api")),
                ComposeService(name: "web", image: nil, build: ComposeBuild(context: "web"))
            ],
            sourcePath: workdir.appendingPathComponent("compose.yaml").path
        )

        let commands = AppleContainerPlanner().planBuild(project: project, services: ["web"])

        XCTAssertEqual(commands.map(\.service), ["web"])
        XCTAssertEqual(commands.first?.arguments.prefix(3), ["build", "--tag", "demo_web:latest"])
    }

    func testPlansInlineDockerfileAsGeneratedBuildFile() throws {
        let workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-build-planner-tests")
            .appendingPathComponent(UUID().uuidString)
        let generatedRoot = workdir.appendingPathComponent("generated")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }

        let inlineDockerfile = """
        FROM scratch
        LABEL app=api

        """
        let project = ComposeProject(
            name: "Demo Project",
            services: [
                ComposeService(
                    name: "api",
                    image: "example/api:dev",
                    build: ComposeBuild(
                        context: "api",
                        dockerfileInline: inlineDockerfile,
                        args: ["APP_ENV=test"]
                    )
                )
            ],
            sourcePath: workdir.appendingPathComponent("compose.yaml").path
        )
        let resolver = AppleContainerInlineDockerfilePathResolver(rootDirectory: generatedRoot.path)
        let expectedPath = resolver.path(
            projectName: project.name,
            serviceName: "api",
            sourcePath: project.sourcePath,
            buildContext: "api",
            contents: inlineDockerfile
        )

        let command = try XCTUnwrap(AppleContainerPlanner(inlineDockerfilePathResolver: resolver)
            .planBuild(project: project)
            .first)

        XCTAssertEqual(command.arguments, [
            "build",
            "--tag",
            "example/api:dev",
            "--file",
            expectedPath,
            "--build-arg",
            "APP_ENV=test",
            workdir.appendingPathComponent("api").path
        ])
        XCTAssertEqual(command.generatedFiles, [
            PlannedGeneratedFile(
                kind: .inlineDockerfile,
                path: expectedPath,
                contents: inlineDockerfile,
                diagnosticsPath: "services.api.build.dockerfile_inline"
            )
        ])
        XCTAssertFalse(command.diagnostics.contains { $0.path == "services.api.build.dockerfile_inline" })
    }

    func testExplicitBuildPullPolicyKeepsBuildPlanningWhenImageIsAlsoSet() throws {
        let workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-build-planner-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }

        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "api",
                    image: "example/api:dev",
                    pullPolicy: "build",
                    build: ComposeBuild(context: ".")
                )
            ],
            sourcePath: workdir.appendingPathComponent("compose.yaml").path
        )

        let commands = AppleContainerPlanner().planUp(project: project)

        XCTAssertEqual(commands.map(\.action), [.buildService, .runService])
        XCTAssertFalse(commands[1].diagnostics.contains { $0.path == "services.api.pull_policy" })
    }

    func testImageAndBuildWithoutPullPolicySurfacesComposeFallbackDiagnostic() throws {
        let workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-build-planner-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }

        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "api",
                    image: "example/api:dev",
                    build: ComposeBuild(context: ".")
                )
            ],
            sourcePath: workdir.appendingPathComponent("compose.yaml").path
        )

        let commands = AppleContainerPlanner().planUp(project: project)
        let run = try XCTUnwrap(commands.first { $0.action == .runService })

        XCTAssertEqual(commands.map(\.action), [.buildService, .runService])
        XCTAssertTrue(run.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.api.pull_policy"
            && $0.message.contains("pulls the image first")
        })
    }

    func testPlansRunWithHealthcheckDiagnostic() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "api",
                    image: "example/api",
                    healthcheck: ComposeHealthcheck(test: ["CMD", "curl", "-f", "http://localhost/health"])
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.api.healthcheck"
            && $0.message.contains("not mapped")
        })
    }

    func testHealthyDependsOnWithoutHealthcheckProducesDiagnostic() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    dependsOn: ["api"],
                    dependsOnMetadata: [
                        "api": ComposeServiceDependencyMetadata(condition: .serviceHealthy)
                    ]
                ),
                ComposeService(name: "api", image: "example/api")
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.service == "web" })

        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.depends_on.api.condition"
            && $0.message.contains("no enabled healthcheck")
        })
    }

    func testPlansBuildObjectOptionsAsAppleContainerBuildArguments() throws {
        let workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-build-planner-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }
        let resolvedWorkdir = workdir.standardizedFileURL

        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "api",
                    image: "example/api:dev",
                    build: ComposeBuild(
                        context: ".",
                        dockerfile: "Dockerfile.api",
                        args: ["GIT_COMMIT=abc123"],
                        labels: ["com.example.stage=dev"],
                        target: "runtime",
                        tags: ["example/api:latest"],
                        noCache: true,
                        pull: true,
                        platforms: ["linux/arm64"]
                    )
                )
            ],
            sourcePath: workdir.appendingPathComponent("compose.yaml").path
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first)

        XCTAssertEqual(command.action, .buildService)
        XCTAssertEqual(command.arguments, [
            "build",
            "--tag",
            "example/api:dev",
            "--tag",
            "example/api:latest",
            "--file",
            resolvedWorkdir.appendingPathComponent("Dockerfile.api").path,
            "--build-arg",
            "GIT_COMMIT=abc123",
            "--label",
            "com.example.stage=dev",
            "--target",
            "runtime",
            "--no-cache",
            "--pull",
            "--platform",
            "linux/arm64",
            resolvedWorkdir.path
        ])
    }

    func testPlansFileAndEnvironmentBuildSecretsAsBuildArguments() throws {
        let workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-build-planner-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }
        try "secret\n".write(to: workdir.appendingPathComponent("npm.token"), atomically: true, encoding: .utf8)
        let resolvedWorkdir = workdir.standardizedFileURL

        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "api",
                    image: "example/api:dev",
                    build: ComposeBuild(
                        context: ".",
                        secrets: [
                            ComposeServiceResourceGrant(source: "npm-token", target: "/run/secrets/npm-token"),
                            ComposeServiceResourceGrant(source: "signing-key", target: "/run/secrets/cert", mode: "0440"),
                            ComposeServiceResourceGrant(source: "external-token", target: "/run/secrets/external-token"),
                            ComposeServiceResourceGrant(source: "missing-secret", target: "/run/secrets/missing-secret")
                        ]
                    )
                )
            ],
            secrets: [
                "npm-token": ComposeSecret(name: "npm-token", file: "./npm.token"),
                "signing-key": ComposeSecret(name: "signing-key", environment: "SIGNING_KEY"),
                "external-token": ComposeSecret(name: "external-token", external: true)
            ],
            sourcePath: workdir.appendingPathComponent("compose.yaml").path
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first)

        XCTAssertEqual(command.action, .buildService)
        XCTAssertTrue(command.arguments.contains("--secret"))
        XCTAssertTrue(command.arguments.contains("id=npm-token,src=\(resolvedWorkdir.appendingPathComponent("npm.token").path)"))
        XCTAssertTrue(command.arguments.contains("id=cert,env=SIGNING_KEY"))
        XCTAssertFalse(command.arguments.contains { $0.contains("external-token,") })
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning && $0.path == "services.api.build.secrets.signing-key"
        })
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning && $0.path == "secrets.external-token"
        })
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .error && $0.path == "services.api.build.secrets.missing-secret"
        })
    }

    func testPreservedUnsupportedBuildFieldsEmitPlannerDiagnostics() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "api",
                    image: "example/api:dev",
                    build: ComposeBuild(
                        context: ".",
                        additionalContexts: ["resources=./resources"],
                        dockerfile: "Dockerfile",
                        dockerfileInline: "FROM scratch\n",
                        cacheFrom: ["example/cache"],
                        cacheTo: ["type=local,dest=.build-cache"],
                        entitlements: ["network.host"],
                        extraHosts: ["db.local=10.0.0.5"],
                        isolation: "default",
                        network: "host",
                        privileged: true,
                        shmSize: "128m",
                        ssh: ["default"],
                        provenance: "true",
                        sbom: "generator=docker/scout-sbom-indexer:latest",
                        ulimits: ["nofile=1024:2048"]
                    )
                )
            ],
            sourcePath: "/tmp/demo/compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first)
        let diagnosticPaths = command.diagnostics.map(\.path)

        XCTAssertTrue(diagnosticPaths.contains("services.api.build.additional_contexts"))
        XCTAssertTrue(diagnosticPaths.contains("services.api.build"))
        XCTAssertTrue(diagnosticPaths.contains("services.api.build.cache_from"))
        XCTAssertTrue(diagnosticPaths.contains("services.api.build.cache_to"))
        XCTAssertTrue(diagnosticPaths.contains("services.api.build.entitlements"))
        XCTAssertTrue(diagnosticPaths.contains("services.api.build.extra_hosts"))
        XCTAssertTrue(diagnosticPaths.contains("services.api.build.isolation"))
        XCTAssertTrue(diagnosticPaths.contains("services.api.build.network"))
        XCTAssertTrue(diagnosticPaths.contains("services.api.build.privileged"))
        XCTAssertTrue(diagnosticPaths.contains("services.api.build.shm_size"))
        XCTAssertTrue(diagnosticPaths.contains("services.api.build.ssh"))
        XCTAssertTrue(diagnosticPaths.contains("services.api.build.provenance"))
        XCTAssertTrue(diagnosticPaths.contains("services.api.build.sbom"))
        XCTAssertTrue(diagnosticPaths.contains("services.api.build.ulimits"))
        XCTAssertFalse(command.arguments.contains { $0.contains("example/cache") })
        XCTAssertFalse(command.arguments.contains { $0.contains("resources=./resources") })
    }

    func testPlansServiceLabelsAsRunArguments() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    labels: [
                        "com.example.role=frontend",
                        "com.example.flag"
                    ]
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first)

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "--label",
            "com.example.role=frontend",
            "--label",
            "com.example.flag",
            "nginx"
        ])
    }

    func testPlansCustomContainerNameAcrossLifecycleCommands() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", containerName: "public-web")
            ],
            sourcePath: "compose.yaml"
        )

        XCTAssertEqual(
            AppleContainerPlanner().planUp(project: project).first { $0.action == .runService }?.arguments,
            ["run", "--name", "public-web", "--detach", "nginx"]
        )
        XCTAssertEqual(
            AppleContainerPlanner().planStart(project: project).map(\.arguments),
            [["start", "public-web"]]
        )
        XCTAssertEqual(
            AppleContainerPlanner().planStop(project: project).map(\.arguments),
            [["stop", "public-web"]]
        )
        XCTAssertEqual(
            AppleContainerPlanner().planRestart(project: project).map(\.arguments),
            [["stop", "public-web"], ["start", "public-web"]]
        )
        XCTAssertEqual(
            AppleContainerPlanner().planLogs(project: project).map(\.arguments),
            [["logs", "public-web"]]
        )
        XCTAssertEqual(
            AppleContainerPlanner().planDown(project: project).map(\.arguments),
            [["stop", "public-web"], ["delete", "--force", "public-web"]]
        )
    }

    func testPlansMappedServiceRunOptions() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    initProcess: true,
                    stdinOpen: true,
                    tty: true,
                    readOnly: true,
                    capAdd: ["NET_ADMIN"],
                    capDrop: ["MKNOD"],
                    dns: ["1.1.1.1"],
                    dnsSearch: ["svc.local"],
                    dnsOptions: ["ndots:0"],
                    shmSize: "128m",
                    tmpfs: ["/run", "/tmp:size=64m"],
                    ulimits: ["nofile=20000:40000", "nproc=65535"]
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "--init",
            "--interactive",
            "--tty",
            "--read-only",
            "--cap-add",
            "NET_ADMIN",
            "--cap-drop",
            "MKNOD",
            "--dns",
            "1.1.1.1",
            "--dns-search",
            "svc.local",
            "--dns-option",
            "ndots:0",
            "--shm-size",
            "128m",
            "--tmpfs",
            "/run",
            "--tmpfs",
            "/tmp:size=64m",
            "--ulimit",
            "nofile=20000:40000",
            "--ulimit",
            "nproc=65535",
            "nginx"
        ])
        XCTAssertTrue(command.diagnostics.isEmpty)
    }

    func testOptionalMissingServiceEnvFileIsSkippedAndFormatWarns() throws {
        let workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-env-file-planner-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }
        try "APP_ENV=local\n".write(to: workdir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    envFiles: [".env", "missing.env", "raw.env"],
                    envFileEntries: [
                        ComposeEnvFile(path: ".env"),
                        ComposeEnvFile(path: "missing.env", required: false),
                        ComposeEnvFile(path: "raw.env", format: "raw")
                    ]
                )
            ],
            sourcePath: workdir.appendingPathComponent("compose.yaml").path
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "--env-file",
            ".env",
            "--env-file",
            "raw.env",
            "nginx"
        ])
        XCTAssertTrue(command.diagnostics.contains {
            $0.path == "services.web.env_file" && $0.message.contains("missing.env")
        })
        XCTAssertTrue(command.diagnostics.contains {
            $0.path == "services.web.env_file" && $0.message.contains("format 'raw'")
        })
    }

    func testPreservedServiceExtraHostsEmitPlannerDiagnostic() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    extraHosts: ["db.local=10.0.0.5"]
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.extra_hosts"
            && $0.message.contains("not mapped to Apple Container run arguments yet")
        })
    }

    func testServiceExposeDoesNotPublishHostPortsAndEmitsPlannerDiagnostic() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    exposedPorts: ["3000", "8080-8085/tcp"]
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--publish"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.expose"
            && $0.message.contains("internal-only Compose ports")
        })
    }

    func testServicePrivilegedEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    privileged: true
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--privileged"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.privileged"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceHostnameEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    hostname: "web-01"
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--hostname"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.hostname"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceDomainNameEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    domainName: "example.local"
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--domainname"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.domainname"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceNetworkModeEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    networkMode: "host"
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--network"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.network_mode"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceMACAddressEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    macAddress: "02:42:ac:11:00:02"
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--mac-address"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.mac_address"
            && $0.message.contains("not mapped")
        })
    }

    func testServicePIDModeEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    pidMode: "host"
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--pid"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.pid"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceIPCModeEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    ipcMode: "shareable"
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--ipc"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.ipc"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceUTSModeEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    utsMode: "host"
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--uts"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.uts"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceUserNamespaceModeEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    usernsMode: "host"
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--userns"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.userns_mode"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceIsolationEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    isolation: "hyperv"
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--isolation"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.isolation"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceCgroupModeEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    cgroupMode: "private"
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--cgroup"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.cgroup"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceCgroupParentEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    cgroupParent: "m-executor-abcd"
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--cgroup-parent"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.cgroup_parent"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceDeviceCgroupRulesEmitPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    deviceCgroupRules: ["c 1:3 mr", "a 7:* rmw"]
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--device-cgroup-rule"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.device_cgroup_rules"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceDevicesEmitPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    devices: ["/dev/ttyUSB0:/dev/ttyUSB0", "vendor1.com/device=gpu"]
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--device"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.devices"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceGPUsEmitPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "model",
                    image: "local/model",
                    gpus: ComposeGPURequest(all: true)
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_model_1",
            "--detach",
            "local/model"
        ])
        XCTAssertFalse(command.arguments.contains("--gpus"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.model.gpus"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceModelGrantsEmitPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "api",
                    image: "example/api",
                    modelGrants: [
                        ComposeServiceModelGrant(name: "llm", endpointVariable: "LLM_URL", modelVariable: "LLM_MODEL")
                    ]
                )
            ],
            models: [
                "llm": ComposeModelDefinition(name: "llm", model: "ai/smollm2")
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_api_1",
            "--detach",
            "example/api"
        ])
        XCTAssertFalse(command.arguments.contains("LLM_URL"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.api.models"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceDevelopEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "frontend",
                    image: "example/webapp",
                    develop: ComposeDevelop(watch: [
                        ComposeDevelopWatchRule(
                            path: "./webapp/html",
                            action: "sync",
                            target: "/var/www",
                            initialSync: true
                        )
                    ])
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_frontend_1",
            "--detach",
            "example/webapp"
        ])
        XCTAssertFalse(command.arguments.contains("./webapp/html"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.frontend.develop"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceDeployEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "api",
                    image: "example/api",
                    deploy: ComposeDeploy(
                        mode: "replicated",
                        replicas: 3,
                        resources: ComposeDeployResources(
                            reservations: ComposeDeployResourceSpec(cpus: "0.25", memory: "128M")
                        ),
                        updateConfig: ComposeDeployUpdateConfig(parallelism: 1, order: "start-first")
                    )
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_api_1",
            "--detach",
            "example/api"
        ])
        XCTAssertFalse(command.arguments.contains("replicated"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.api.deploy"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceGroupAddEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "alpine",
                    groupAdd: ["mail", "44"]
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "alpine"
        ])
        XCTAssertFalse(command.arguments.contains("--group-add"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.group_add"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceSysctlsEmitPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    sysctls: ["net.core.somaxconn": "1024"]
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--sysctl"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.sysctls"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceOOMControlsEmitPlannerDiagnosticsWithoutRunFlags() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "worker",
                    image: "alpine",
                    oomKillDisable: true,
                    oomScoreAdjustment: -500
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_worker_1",
            "--detach",
            "alpine"
        ])
        XCTAssertFalse(command.arguments.contains("--oom-kill-disable"))
        XCTAssertFalse(command.arguments.contains("--oom-score-adj"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.worker.oom_kill_disable"
            && $0.message.contains("not mapped")
        })
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.worker.oom_score_adj"
            && $0.message.contains("not mapped")
        })
    }

    func testServicePIDsLimitEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "worker",
                    image: "alpine",
                    pidsLimit: 64
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_worker_1",
            "--detach",
            "alpine"
        ])
        XCTAssertFalse(command.arguments.contains("--pids-limit"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.worker.pids_limit"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceLoggingEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    logging: ComposeLogging(
                        driver: "json-file",
                        options: ["max-size": "10m"]
                    )
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--log-driver"))
        XCTAssertFalse(command.arguments.contains("--log-opt"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.logging"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceRuntimeScaleStorageOptionsAndAPISocketEmitPlannerDiagnosticsWithoutRunFlags() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    runtime: "io.containerd.runc.v2",
                    scale: 3,
                    storageOptions: ["size": "1G"],
                    useAPISocket: true
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--runtime"))
        XCTAssertFalse(command.arguments.contains("--storage-opt"))
        for path in [
            "services.web.runtime",
            "services.web.scale",
            "services.web.storage_opt",
            "services.web.use_api_socket"
        ] {
            XCTAssertTrue(command.diagnostics.contains {
                $0.severity == .warning
                && $0.path == path
            }, "Missing diagnostic for \(path)")
        }
    }

    func testServiceLifecycleHooksEmitPlannerDiagnosticsWithoutRunFlags() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    postStartHooks: [ComposeLifecycleHook(command: ["./after-start.sh"])],
                    preStartHooks: [ComposeLifecycleHook(command: ["./migrate.sh"], image: "busybox")],
                    preStopHooks: [ComposeLifecycleHook(command: ["./before-stop.sh"])]
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("./after-start.sh"))
        XCTAssertFalse(command.arguments.contains("./migrate.sh"))
        XCTAssertFalse(command.arguments.contains("./before-stop.sh"))
        for path in [
            "services.web.post_start",
            "services.web.pre_start",
            "services.web.pre_stop"
        ] {
            XCTAssertTrue(command.diagnostics.contains {
                $0.severity == .warning
                && $0.path == path
            }, "Missing diagnostic for \(path)")
        }
    }

    func testServiceProviderPlansDelegatedDiagnosticCommandWithoutImageRequirement() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "database",
                    image: nil,
                    provider: ComposeProvider(type: "awesomecloud", options: ["type": "mysql"])
                ),
                ComposeService(
                    name: "web",
                    image: "nginx",
                    dependsOn: ["database"]
                )
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planUp(project: project)

        XCTAssertEqual(commands.map(\.action), [.delegateService, .runService])
        XCTAssertEqual(commands[0].service, "database")
        XCTAssertEqual(commands[0].arguments, ["compose-provider", "run", "database", "awesomecloud"])
        XCTAssertFalse(commands[0].diagnostics.contains {
            $0.path == "services.database.image"
            && $0.message.contains("requires an image")
        })
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.database.provider"
            && $0.message.contains("delegated provider lifecycle")
        })
        XCTAssertEqual(commands[1].service, "web")

        let plan = AppleContainerPlan(project: project, operation: "up", commands: commands)
        XCTAssertEqual(plan.executionGraph?.edges, [
            AppleContainerExecutionEdge(
                fromCommandIndex: 0,
                toCommandIndex: 1,
                dependencyMetadata: .init(condition: .serviceStarted, restart: false, required: true)
            )
        ])
        XCTAssertEqual(plan.executionGraph?.nodes[1].dependsOnCommandIndexes, [0])
    }

    func testServiceCredentialSpecEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    credentialSpec: ComposeCredentialSpec(file: "my-credential-spec.json")
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--credential-spec"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.credential_spec"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceVolumesFromActsAsDependencyAndEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "data", image: "busybox"),
                ComposeService(
                    name: "web",
                    image: "nginx",
                    volumesFrom: ["data:ro", "container:legacy-data"],
                    dependsOn: ["data"]
                )
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planUp(project: project)
        let runCommands = commands.filter { $0.action == .runService }
        let web = try XCTUnwrap(runCommands.first { $0.service == "web" })

        XCTAssertEqual(runCommands.map(\.service), ["data", "web"])
        XCTAssertEqual(web.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(web.arguments.contains("--volume"))
        XCTAssertTrue(web.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.volumes_from"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceLinksActAsDependenciesAndEmitPlannerDiagnosticWithoutRunFlag() throws {
        let yaml = """
        name: demo
        services:
          db:
            image: postgres
          web:
            image: nginx
            links:
              - db:database
        """

        let project = try ComposeLoader().load(yaml: yaml)

        let commands = AppleContainerPlanner().planUp(project: project, services: ["web"])

        XCTAssertEqual(commands.map(\.service), [nil, "db", "web"])
        XCTAssertEqual(commands[0].arguments, ["network", "create", "demo_default"])
        XCTAssertEqual(commands[2].arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "--network",
            "demo_default",
            "nginx"
        ])
        XCTAssertFalse(commands[2].arguments.contains("--link"))
        XCTAssertTrue(commands[2].diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.links"
            && $0.message.contains("startup dependencies")
        })
    }

    func testServiceExternalLinksEmitPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    externalLinks: ["database:mysql"]
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--link"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.external_links"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceAnnotationsEmitPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    annotations: ["com.example.role=frontend"]
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--annotation"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.annotations"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceAttachFalseEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    attach: false
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.attach"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceBlockIOConfigEmitsPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    blockIOConfig: ComposeBlockIOConfig(
                        weight: 300,
                        deviceReadBps: [
                            ComposeBlockIODeviceRate(path: "/dev/sdb", rate: "12mb")
                        ]
                    )
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--blkio-weight"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.blkio_config"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceCPUSchedulerFieldsEmitPlannerDiagnosticsWithoutRunFlags() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    cpuCount: 4,
                    cpuPercent: 80,
                    cpuShares: 1024,
                    cpuPeriod: 100_000,
                    cpuQuota: 50_000,
                    cpuRTRuntime: "400ms",
                    cpuRTPeriod: "1400us",
                    cpuSet: "0-3"
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--cpu-shares"))
        for path in [
            "services.web.cpu_count",
            "services.web.cpu_percent",
            "services.web.cpu_shares",
            "services.web.cpu_period",
            "services.web.cpu_quota",
            "services.web.cpu_rt_runtime",
            "services.web.cpu_rt_period",
            "services.web.cpuset"
        ] {
            XCTAssertTrue(command.diagnostics.contains {
                $0.severity == .warning
                && $0.path == path
                && $0.message.contains("not mapped")
            }, "Missing diagnostic for \(path)")
        }
    }

    func testServiceMemoryReservationAndSwappinessEmitPlannerDiagnosticsWithoutRunFlags() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    memoryReservation: "256m",
                    memorySwappiness: 25
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--memory-reservation"))
        XCTAssertFalse(command.arguments.contains("--memory-swappiness"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.mem_reservation"
            && $0.message.contains("not mapped")
        })
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.mem_swappiness"
            && $0.message.contains("not mapped")
        })
    }

    func testServiceSecurityOptionsEmitPlannerDiagnosticWithoutRunFlag() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    securityOptions: ["label:user:USER", "no-new-privileges:true"]
                )
            ],
            sourcePath: "compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertEqual(command.arguments, [
            "run",
            "--name",
            "demo_web_1",
            "--detach",
            "nginx"
        ])
        XCTAssertFalse(command.arguments.contains("--security-opt"))
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.security_opt"
            && $0.message.contains("not mapped to Apple Container run arguments yet")
        })
    }

    func testPlansOneOffRunWithOverridesAndNoServicePortsByDefault() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx:alpine",
                    command: ["nginx"],
                    entrypoint: "/docker-entrypoint.sh",
                    environment: ["BASE": "1"],
                    ports: ["8080:80"]
                )
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planRun(
            project: project,
            service: "web",
            options: .init(
                remove: true,
                publish: ["9090:90"],
                name: "task",
                entrypoint: "/bin/sh",
                command: ["-lc", "echo ok"],
                environment: ["EXTRA=2"],
                user: "1000",
                workdir: "/app"
            )
        )

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, PlanAction.runService)
        XCTAssertEqual(commands[0].arguments, [
            "run",
            "--name",
            "task",
            "--rm",
            "--interactive",
            "--tty",
            "--entrypoint",
            "/bin/sh",
            "--env",
            "BASE=1",
            "--env",
            "EXTRA=2",
            "--publish",
            "9090:90",
            "--workdir",
            "/app",
            "--user",
            "1000",
            "nginx:alpine",
            "-lc",
            "echo ok"
        ])
        XCTAssertFalse(commands[0].arguments.contains("8080:80"))
    }

    func testPlansOneOffRunWithDependenciesAndBuildPrerequisite() throws {
        let workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-run-planner-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }

        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: nil,
                    build: ComposeBuild(context: "web"),
                    volumes: ["cache:/cache"],
                    networks: ["front"],
                    dependsOn: ["db"]
                ),
                ComposeService(name: "db", image: "postgres")
            ],
            networks: ["front": ComposeNetwork(name: "front")],
            volumes: ["cache": ComposeVolume(name: "cache")],
            sourcePath: workdir.appendingPathComponent("compose.yaml").path
        )

        let commands = AppleContainerPlanner().planRun(project: project, service: "web")

        XCTAssertEqual(commands.map(\.action), [.runService, .createNetwork, .createVolume, .buildService, .runService])
        XCTAssertEqual(commands[0].service, "db")
        XCTAssertEqual(commands[1].arguments, ["network", "create", "demo_front"])
        XCTAssertEqual(commands[2].arguments, ["volume", "create", "demo_cache"])
        XCTAssertEqual(commands[3].service, "web")
        XCTAssertEqual(commands[4].service, "web")
        XCTAssertTrue(commands[4].arguments.contains("demo_web_run_1"))
        XCTAssertTrue(commands[4].arguments.contains("demo_cache:/cache"))
        XCTAssertTrue(commands[4].arguments.contains("demo_front"))
        XCTAssertEqual(commands[4].arguments.suffix(1), ["demo_web:latest"])
    }

    func testPlansOneOffRunNoDependencies() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", dependsOn: ["db"]),
                ComposeService(name: "db", image: "postgres")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planRun(
            project: project,
            service: "web",
            options: .init(noDependencies: true, servicePorts: true)
        )

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].arguments, [
            "run",
            "--name",
            "demo_web_run_1",
            "--interactive",
            "--tty",
            "nginx"
        ])
    }

    func testPlansFileBackedConfigsAndSecretsAsReadOnlyVolumes() throws {
        let workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-planner-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }

        try FileManager.default.createDirectory(
            at: workdir.appendingPathComponent("config"),
            withIntermediateDirectories: true
        )
        try "debug=true\n".write(to: workdir.appendingPathComponent("config/app.env"), atomically: true, encoding: .utf8)
        try "secret\n".write(to: workdir.appendingPathComponent("db.password"), atomically: true, encoding: .utf8)

        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    configs: [
                        ComposeServiceResourceGrant(source: "app-config", target: "/etc/app/app.env")
                    ],
                    secrets: [
                        ComposeServiceResourceGrant(source: "db-password", target: "/run/secrets/db-password")
                    ]
                )
            ],
            configs: [
                "app-config": ComposeConfig(name: "app-config", file: "./config/app.env")
            ],
            secrets: [
                "db-password": ComposeSecret(name: "db-password", file: "./db.password")
            ],
            sourcePath: workdir.appendingPathComponent("compose.yaml").path
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertTrue(command.arguments.contains("--volume"))
        XCTAssertTrue(command.arguments.contains("\(workdir.path)/config/app.env:/etc/app/app.env:ro"))
        XCTAssertTrue(command.arguments.contains("\(workdir.path)/db.password:/run/secrets/db-password:ro"))
        XCTAssertTrue(command.diagnostics.isEmpty)
    }

    func testPlannerWarnsAndSkipsUnsupportedConfigAndSecretSources() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    configs: [
                        ComposeServiceResourceGrant(source: "inline-config", target: "/inline"),
                        ComposeServiceResourceGrant(source: "missing-config", target: "/missing")
                    ],
                    secrets: [
                        ComposeServiceResourceGrant(source: "external-secret", target: "/run/secrets/external")
                    ]
                )
            ],
            configs: [
                "inline-config": ComposeConfig(name: "inline-config", content: "debug=true")
            ],
            secrets: [
                "external-secret": ComposeSecret(name: "external-secret", external: true)
            ],
            sourcePath: "/tmp/demo/compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertFalse(command.arguments.contains { $0.contains("/inline:ro") })
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning && $0.path == "configs.inline-config"
        })
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning && $0.path == "secrets.external-secret"
        })
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .error && $0.path == "services.web.configs.missing-config"
        })
    }

    func testPlannerWarnsAndSkipsMissingConfigAndSecretFiles() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    configs: [
                        ComposeServiceResourceGrant(source: "app-config", target: "/etc/app/app.env")
                    ],
                    secrets: [
                        ComposeServiceResourceGrant(source: "db-password", target: "/run/secrets/db-password")
                    ]
                )
            ],
            configs: [
                "app-config": ComposeConfig(name: "app-config", file: "./missing.env")
            ],
            secrets: [
                "db-password": ComposeSecret(name: "db-password", file: "./missing.secret")
            ],
            sourcePath: "/tmp/demo/compose.yaml"
        )

        let command = try XCTUnwrap(AppleContainerPlanner().planUp(project: project).first { $0.action == .runService })

        XCTAssertFalse(command.arguments.contains { $0.contains("missing.env") })
        XCTAssertFalse(command.arguments.contains { $0.contains("missing.secret") })
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning && $0.path == "configs.app-config.file"
        })
        XCTAssertTrue(command.diagnostics.contains {
            $0.severity == .warning && $0.path == "secrets.db-password.file"
        })
    }

    func testPlansServiceStartCommandsForAllServices() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", dependsOn: ["db"]),
                ComposeService(name: "db", image: "postgres")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planStart(project: project)

        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.map(\.action), [.startService, .startService])
        XCTAssertEqual(commands[0].service, "db")
        XCTAssertEqual(commands[0].arguments, ["start", "demo_db_1"])
        XCTAssertEqual(commands[1].service, "web")
        XCTAssertEqual(commands[1].arguments, ["start", "demo_web_1"])
    }

    func testPlansStopCommandsForSelectedServicesInReverseStartOrder() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", dependsOn: ["db"]),
                ComposeService(name: "db", image: "postgres")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planStop(project: project, services: ["db", "web"])

        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].action, .stopService)
        XCTAssertEqual(commands[0].service, "web")
        XCTAssertEqual(commands[0].arguments, ["stop", "demo_web_1"])
        XCTAssertEqual(commands[1].action, .stopService)
        XCTAssertEqual(commands[1].service, "db")
        XCTAssertEqual(commands[1].arguments, ["stop", "demo_db_1"])
    }

    func testPlansRestartCommandsAsStopThenStartPerService() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", dependsOn: ["db"]),
                ComposeService(name: "db", image: "postgres")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planRestart(project: project)

        XCTAssertEqual(commands.count, 4)
        XCTAssertEqual(commands[0].action, .stopService)
        XCTAssertEqual(commands[0].service, "web")
        XCTAssertEqual(commands[0].arguments, ["stop", "demo_web_1"])
        XCTAssertEqual(commands[1].action, .stopService)
        XCTAssertEqual(commands[1].service, "db")
        XCTAssertEqual(commands[1].arguments, ["stop", "demo_db_1"])

        XCTAssertEqual(commands[2].action, .restartService)
        XCTAssertEqual(commands[2].service, "db")
        XCTAssertEqual(commands[2].arguments, ["start", "demo_db_1"])

        XCTAssertEqual(commands[3].action, .restartService)
        XCTAssertEqual(commands[3].service, "web")
        XCTAssertEqual(commands[3].arguments, ["start", "demo_web_1"])
    }

    func testPlansKillCommandsForSelectedServicesInReverseStartOrder() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", dependsOn: ["db"]),
                ComposeService(name: "db", image: "postgres", containerName: "database")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planKill(project: project, services: ["db", "web"], signal: "SIGINT")

        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].action, .killService)
        XCTAssertEqual(commands[0].service, "web")
        XCTAssertEqual(commands[0].arguments, ["kill", "--signal", "SIGINT", "demo_web_1"])
        XCTAssertEqual(commands[1].action, .killService)
        XCTAssertEqual(commands[1].service, "db")
        XCTAssertEqual(commands[1].arguments, ["kill", "--signal", "SIGINT", "database"])
    }

    func testPlansPauseCommandsWithUnsupportedRuntimeDiagnostic() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", dependsOn: ["db"]),
                ComposeService(name: "db", image: "postgres", containerName: "database")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planPause(project: project, services: ["db", "web"])

        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].action, .pauseService)
        XCTAssertEqual(commands[0].service, "db")
        XCTAssertEqual(commands[0].arguments, ["pause", "database"])
        XCTAssertEqual(commands[1].action, .pauseService)
        XCTAssertEqual(commands[1].service, "web")
        XCTAssertEqual(commands[1].arguments, ["pause", "demo_web_1"])
        XCTAssertTrue(commands.allSatisfy { command in
            command.diagnostics.contains {
                $0.severity == .warning
                && $0.path == "pause"
                && $0.message.contains("not executable yet")
            }
        })
    }

    func testPlansUnpauseCommandsWithUnsupportedRuntimeDiagnostic() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", dependsOn: ["db"]),
                ComposeService(name: "db", image: "postgres", containerName: "database")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planUnpause(project: project, services: ["db", "web"])

        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].action, .unpauseService)
        XCTAssertEqual(commands[0].service, "db")
        XCTAssertEqual(commands[0].arguments, ["unpause", "database"])
        XCTAssertEqual(commands[1].action, .unpauseService)
        XCTAssertEqual(commands[1].service, "web")
        XCTAssertEqual(commands[1].arguments, ["unpause", "demo_web_1"])
        XCTAssertTrue(commands.allSatisfy { command in
            command.diagnostics.contains {
                $0.severity == .warning
                && $0.path == "unpause"
                && $0.message.contains("not executable yet")
            }
        })
    }

    func testPlansAttachCommandWithUnsupportedRuntimeDiagnosticAndOptions() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx"),
                ComposeService(name: "db", image: "postgres")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planAttach(
            project: project,
            service: "web",
            options: .init(
                detachKeys: "ctrl-c",
                replicaIndex: 2,
                attachStdin: false,
                signalProxy: false
            )
        )

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .attachService)
        XCTAssertEqual(commands[0].service, "web")
        XCTAssertEqual(commands[0].arguments, [
            "attach",
            "--detach-keys", "ctrl-c",
            "--index", "2",
            "--no-stdin",
            "--sig-proxy=false",
            "demo_web_2"
        ])
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "attach"
                && $0.message.contains("not executable yet")
        })
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "attach.detach_keys"
        })
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "attach.sig_proxy"
        })
    }

    func testPlansWaitCommandsWithUnsupportedRuntimeDiagnosticAndDownProjectIntent() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", dependsOn: ["db"]),
                ComposeService(name: "db", image: "postgres", containerName: "database")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planWait(
            project: project,
            services: ["db", "web"],
            options: .init(downProject: true)
        )

        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].action, .waitService)
        XCTAssertEqual(commands[0].service, "db")
        XCTAssertEqual(commands[0].arguments, ["wait", "--down-project", "database"])
        XCTAssertEqual(commands[1].action, .waitService)
        XCTAssertEqual(commands[1].service, "web")
        XCTAssertEqual(commands[1].arguments, ["wait", "--down-project", "demo_web_1"])
        XCTAssertTrue(commands.allSatisfy { command in
            command.diagnostics.contains {
                $0.severity == .warning
                    && $0.path == "wait"
                    && $0.message.contains("not executable yet")
            }
        })
        XCTAssertTrue(commands.allSatisfy { command in
            command.diagnostics.contains {
                $0.severity == .warning
                    && $0.path == "wait.down_project"
            }
        })
    }

    func testPlansScaleCommandsWithUnsupportedRuntimeDiagnostic() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", dependsOn: ["db"]),
                ComposeService(name: "db", image: "postgres", containerName: "database")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planScale(
            project: project,
            targets: ["db": 2, "web": 3],
            services: ["db", "web"],
            options: .init(noDependencies: true)
        )

        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].action, .scaleService)
        XCTAssertEqual(commands[0].service, "db")
        XCTAssertEqual(commands[0].arguments, ["scale", "--no-deps", "db=2"])
        XCTAssertEqual(commands[1].action, .scaleService)
        XCTAssertEqual(commands[1].service, "web")
        XCTAssertEqual(commands[1].arguments, ["scale", "--no-deps", "web=3"])
        XCTAssertTrue(commands.allSatisfy { command in
            command.diagnostics.contains {
                $0.severity == .warning
                    && $0.path == "scale"
                    && $0.message.contains("not executable yet")
            }
        })
        XCTAssertTrue(commands.allSatisfy { command in
            command.diagnostics.contains {
                $0.severity == .warning
                    && $0.path == "scale.no_deps"
            }
        })
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "services.db.container_name"
        })
    }

    func testPlansScaleWithoutTargetsAsValidationDiagnostic() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planScale(project: project, targets: [:])

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .scaleService)
        XCTAssertEqual(commands[0].arguments, ["scale"])
        XCTAssertEqual(commands[0].diagnostics.first?.severity, .error)
        XCTAssertEqual(commands[0].diagnostics.first?.path, "scale")
    }

    func testPlansCommitCommandWithUnsupportedRuntimeDiagnosticAndOptions() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planCommit(
            project: project,
            service: "web",
            options: .init(
                author: "Jane Example <jane@example.com>",
                changes: ["ENV DEBUG=1", "LABEL stage=dev"],
                message: "capture debug state",
                replicaIndex: 2,
                pause: false,
                repository: "example/web:debug"
            )
        )

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .commitService)
        XCTAssertEqual(commands[0].service, "web")
        XCTAssertEqual(commands[0].arguments, [
            "commit",
            "--author", "Jane Example <jane@example.com>",
            "--change", "ENV DEBUG=1",
            "--change", "LABEL stage=dev",
            "--message", "capture debug state",
            "--index", "2",
            "--pause=false",
            "demo_web_2",
            "example/web:debug"
        ])
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "commit"
                && $0.message.contains("not executable yet")
        })
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "commit.change"
        })
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "commit.pause"
        })
    }

    func testPlansCommitWithoutServiceAsValidationDiagnostic() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planCommit(project: project, service: nil)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .commitService)
        XCTAssertEqual(commands[0].arguments, ["commit"])
        XCTAssertEqual(commands[0].diagnostics.first?.severity, .error)
        XCTAssertEqual(commands[0].diagnostics.first?.path, "commit.service")
    }

    func testPlansExportCommandWithUnsupportedRuntimeDiagnosticAndOptions() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planExport(
            project: project,
            service: "web",
            options: .init(
                replicaIndex: 2,
                output: "./web.tar"
            )
        )

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .exportService)
        XCTAssertEqual(commands[0].service, "web")
        XCTAssertEqual(commands[0].arguments, [
            "export",
            "--index", "2",
            "--output", "./web.tar",
            "demo_web_2"
        ])
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "export"
                && $0.message.contains("not executable yet")
        })
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "export.output"
        })
    }

    func testPlansExportWithoutServiceAsValidationDiagnostic() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planExport(project: project, service: nil)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .exportService)
        XCTAssertEqual(commands[0].arguments, ["export"])
        XCTAssertEqual(commands[0].diagnostics.first?.severity, .error)
        XCTAssertEqual(commands[0].diagnostics.first?.path, "export.service")
    }

    func testPlansEventsCommandWithUnsupportedRuntimeDiagnosticAndFilters() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", dependsOn: ["db"]),
                ComposeService(name: "db", image: "postgres")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planEvents(
            project: project,
            services: ["web"],
            options: .init(
                outputJSON: true,
                since: "2026-07-05T10:00:00Z",
                until: "2026-07-05T11:00:00Z"
            )
        )

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .eventsProject)
        XCTAssertNil(commands[0].service)
        XCTAssertEqual(commands[0].arguments, [
            "events",
            "--json",
            "--since", "2026-07-05T10:00:00Z",
            "--until", "2026-07-05T11:00:00Z",
            "web"
        ])
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "events"
                && $0.message.contains("not executable yet")
        })
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "events.json"
        })
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "events.since"
        })
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "events.until"
        })
    }

    func testPlansWatchCommandWithUnsupportedRuntimeDiagnosticAndOptions() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    develop: ComposeDevelop(watch: [
                        ComposeDevelopWatchRule(path: "./src", action: "sync", target: "/app")
                    ])
                ),
                ComposeService(name: "db", image: "postgres")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planWatch(
            project: project,
            services: ["web"],
            options: .init(
                noUp: true,
                prune: false,
                quiet: true
            )
        )

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .watchProject)
        XCTAssertNil(commands[0].service)
        XCTAssertEqual(commands[0].arguments, [
            "watch",
            "--no-up",
            "--prune=false",
            "--quiet",
            "web"
        ])
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "watch"
                && $0.message.contains("not executable yet")
        })
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "watch.no_up"
        })
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "watch.prune"
        })
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "watch.quiet"
        })
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "services.web.develop.watch"
        })
    }

    func testPlansPublishCommandWithUnsupportedRuntimeDiagnosticAndOptions() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planPublish(
            project: project,
            options: .init(
                app: true,
                ociVersion: "1.1",
                resolveImageDigests: true,
                withEnvironment: true,
                yes: true,
                repository: "example/app:latest"
            )
        )

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .publishProject)
        XCTAssertNil(commands[0].service)
        XCTAssertEqual(commands[0].arguments, [
            "publish",
            "--app",
            "--oci-version", "1.1",
            "--resolve-image-digests",
            "--with-env",
            "--yes",
            "example/app:latest"
        ])
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "publish"
                && $0.message.contains("not executable yet")
        })
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "publish.app"
        })
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "publish.oci_version"
        })
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "publish.resolve_image_digests"
        })
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "publish.with_env"
        })
    }

    func testPlansPublishWithoutRepositoryAsValidationDiagnostic() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planPublish(project: project)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .publishProject)
        XCTAssertEqual(commands[0].arguments, ["publish"])
        XCTAssertEqual(commands[0].diagnostics.last?.severity, .error)
        XCTAssertEqual(commands[0].diagnostics.last?.path, "publish.repository")
    }

    func testPlansProjectListCommandWithUnsupportedRuntimeDiagnosticAndOptions() {
        let commands = AppleContainerPlanner().planProjectList(options: .init(
            all: true,
            filters: ["status=running", "name=demo"],
            format: "json",
            quiet: true
        ))

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .listProjects)
        XCTAssertNil(commands[0].service)
        XCTAssertEqual(commands[0].arguments, [
            "compose",
            "ls",
            "--all",
            "--filter", "status=running",
            "--filter", "name=demo",
            "--format", "json",
            "--quiet"
        ])
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "ls"
                && $0.message.contains("not executable yet")
        })
        XCTAssertTrue(commands[0].diagnostics.contains {
            $0.severity == .warning
                && $0.path == "ls.filter"
        })
    }

    func testPlansRemoveCommandsForSelectedStoppedServicesInReverseStartOrder() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", dependsOn: ["db"]),
                ComposeService(name: "db", image: "postgres", containerName: "database")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planRemove(project: project, services: ["db", "web"])

        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].action, .deleteService)
        XCTAssertEqual(commands[0].service, "web")
        XCTAssertEqual(commands[0].arguments, ["delete", "demo_web_1"])
        XCTAssertEqual(commands[1].action, .deleteService)
        XCTAssertEqual(commands[1].service, "db")
        XCTAssertEqual(commands[1].arguments, ["delete", "database"])
    }

    func testPlansRemoveWithStopAndVolumeDiagnostic() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planRemove(
            project: project,
            services: ["web"],
            stop: true,
            removeVolumes: true
        )

        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].action, .stopService)
        XCTAssertEqual(commands[0].arguments, ["stop", "demo_web_1"])
        XCTAssertEqual(commands[1].action, .deleteService)
        XCTAssertEqual(commands[1].arguments, ["delete", "demo_web_1"])
        XCTAssertEqual(commands[1].diagnostics.first?.severity, .warning)
        XCTAssertEqual(commands[1].diagnostics.first?.path, "rm.volumes")
    }

    func testPlansExecCommandForServiceWithComposeInteractiveDefaults() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planExec(
            project: project,
            service: "web",
            command: ["sh", "-lc", "echo ok"],
            options: .init(
                environment: ["DEBUG=1"],
                envFiles: [".env.exec"],
                user: "1000:1000",
                workdir: "/app"
            )
        )

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .execService)
        XCTAssertEqual(commands[0].service, "web")
        XCTAssertEqual(commands[0].arguments, [
            "exec",
            "--env", "DEBUG=1",
            "--env-file", ".env.exec",
            "--interactive",
            "--tty",
            "--user", "1000:1000",
            "--workdir", "/app",
            "demo_web_1",
            "sh", "-lc", "echo ok"
        ])
        XCTAssertEqual(commands[0].diagnostics, [])
    }

    func testPlansExecReplicaIndexAndUnsupportedPrivilegedDiagnostic() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "worker", image: "busybox")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planExec(
            project: project,
            service: "worker",
            command: ["printenv"],
            options: .init(detach: true, tty: false, replicaIndex: 2, privileged: true)
        )

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].arguments, ["exec", "--detach", "--interactive", "demo_worker_2", "printenv"])
        XCTAssertEqual(commands[0].diagnostics.first?.severity, .warning)
        XCTAssertEqual(commands[0].diagnostics.first?.path, "exec.privileged")
    }

    func testPlansCopyFromServiceContainerToLocalPath() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planCopy(
            project: project,
            source: "web:/var/log/nginx/access.log",
            destination: "./access.log"
        )

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .copyService)
        XCTAssertEqual(commands[0].service, "web")
        XCTAssertEqual(commands[0].arguments, ["copy", "demo_web_1:/var/log/nginx/access.log", "./access.log"])
        XCTAssertEqual(commands[0].diagnostics, [])
    }

    func testPlansCopyFromLocalPathToIndexedServiceContainerWithDiagnostics() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "worker", image: "busybox")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planCopy(
            project: project,
            source: "./config.json",
            destination: "worker:/etc/config.json",
            options: .init(replicaIndex: 2, archive: true, followLink: true, includeRunContainers: true)
        )

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .copyService)
        XCTAssertEqual(commands[0].service, "worker")
        XCTAssertEqual(commands[0].arguments, ["copy", "./config.json", "demo_worker_2:/etc/config.json"])
        XCTAssertEqual(commands[0].diagnostics.map(\.path), ["cp.archive", "cp.follow_link", "cp.all"])
    }

    func testCopyWithoutServiceEndpointProducesDiagnostic() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planCopy(
            project: project,
            source: "./one",
            destination: "./two"
        )

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .copyService)
        XCTAssertNil(commands[0].service)
        XCTAssertEqual(commands[0].diagnostics.first?.severity, .error)
        XCTAssertEqual(commands[0].diagnostics.first?.path, "cp")
    }

    func testPlansStopSignalAndGracePeriodAsAppleContainerStopOptions() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    stopSignal: "SIGUSR1",
                    stopGracePeriod: "1m30s"
                )
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planStop(project: project)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .stopService)
        XCTAssertEqual(commands[0].service, "web")
        XCTAssertEqual(commands[0].arguments, ["stop", "--signal", "SIGUSR1", "--time", "90", "demo_web_1"])
        XCTAssertEqual(commands[0].diagnostics, [])
    }

    func testInvalidStopGracePeriodProducesDiagnosticAndKeepsStopCommand() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    stopSignal: "SIGTERM",
                    stopGracePeriod: "eventually"
                )
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planStop(project: project)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].arguments, ["stop", "--signal", "SIGTERM", "demo_web_1"])
        XCTAssertEqual(commands[0].diagnostics.first?.severity, .warning)
        XCTAssertEqual(commands[0].diagnostics.first?.path, "services.web.stop_grace_period")
    }

    func testPlansLogsCommandsWithFollowAndTail() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx"),
                ComposeService(name: "db", image: "postgres")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planLogs(
            project: project,
            services: ["web"],
            follow: true,
            tail: 150
        )

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .logsService)
        XCTAssertEqual(commands[0].service, "web")
        XCTAssertEqual(commands[0].arguments, ["logs", "--follow", "-n", "150", "demo_web_1"])
    }

    func testPlansPsAsAppleContainerListWithProjectFilteringDiagnostic() {
        let project = ComposeProject(
            name: "demo",
            services: [ComposeService(name: "web", image: "nginx")],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planPs(project: project, services: ["web"], all: true)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .listServices)
        XCTAssertEqual(commands[0].arguments, ["list", "--all"])
        XCTAssertEqual(commands[0].diagnostics.map(\.path), ["ps", "ps.services"])
        XCTAssertEqual(commands[0].diagnostics.map(\.severity), [.warning, .warning])
    }

    func testPlansPsWithoutAllAsAppleContainerRunningList() {
        let project = ComposeProject(
            name: "demo",
            services: [ComposeService(name: "web", image: "nginx")],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planPs(project: project, all: false)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .listServices)
        XCTAssertNil(commands[0].service)
        XCTAssertEqual(commands[0].arguments, ["list"])
        XCTAssertEqual(commands[0].diagnostics.map(\.path), ["ps"])
    }

    func testPlansStatsForProjectServicesWithNoStream() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", dependsOn: ["db"]),
                ComposeService(name: "db", image: "postgres", containerName: "database")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planStats(project: project, noStream: true)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .statsService)
        XCTAssertNil(commands[0].service)
        XCTAssertEqual(commands[0].arguments, ["stats", "--no-stream", "database", "demo_web_1"])
    }

    func testPlansStatsForSelectedServices() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx"),
                ComposeService(name: "db", image: "postgres")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planStats(project: project, services: ["web"])

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .statsService)
        XCTAssertEqual(commands[0].arguments, ["stats", "demo_web_1"])
    }

    func testPlansTopForSelectedServiceAsInContainerProcessView() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx"),
                ComposeService(name: "db", image: "postgres")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planTop(project: project, services: ["web"])

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].action, .topService)
        XCTAssertEqual(commands[0].service, "web")
        XCTAssertEqual(commands[0].arguments, ["exec", "demo_web_1", "ps"])
        XCTAssertEqual(commands[0].diagnostics.first?.severity, .warning)
        XCTAssertEqual(commands[0].diagnostics.first?.path, "top")
    }

    func testPlanDownRemovesServicesAndProjectNetworksButKeepsVolumesByDefault() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", dependsOn: ["db"]),
                ComposeService(name: "db", image: "postgres")
            ],
            networks: [
                "front": ComposeNetwork(name: "front"),
                "external": ComposeNetwork(name: "shared", external: true)
            ],
            volumes: [
                "data": ComposeVolume(name: "data")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planDown(project: project)

        XCTAssertEqual(commands.map(\.action), [
            .stopService,
            .deleteService,
            .stopService,
            .deleteService,
            .deleteNetwork
        ])
        XCTAssertEqual(commands[0].arguments, ["stop", "demo_web_1"])
        XCTAssertEqual(commands[1].arguments, ["delete", "--force", "demo_web_1"])
        XCTAssertEqual(commands[2].arguments, ["stop", "demo_db_1"])
        XCTAssertEqual(commands[3].arguments, ["delete", "--force", "demo_db_1"])
        XCTAssertEqual(commands[4].arguments, ["network", "delete", "demo_front"])
    }

    func testPlanDownCanRemoveProjectVolumesWhenRequested() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx")
            ],
            networks: [
                "front": ComposeNetwork(name: "front")
            ],
            volumes: [
                "data": ComposeVolume(name: "data"),
                "cache": ComposeVolume(name: "cache", customName: "shared_cache"),
                "external": ComposeVolume(name: "shared-cache", external: true)
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planDown(project: project, removeVolumes: true)

        XCTAssertEqual(commands.map(\.action), [
            .stopService,
            .deleteService,
            .deleteNetwork,
            .deleteVolume
        ])
        XCTAssertEqual(commands[2].arguments, ["network", "delete", "demo_front"])
        XCTAssertEqual(commands[3].arguments, ["volume", "delete", "shared_cache", "demo_data"])
    }

    func testAppleContainerPlanEnvelopeCarriesStableProjectMetadata() throws {
        let project = ComposeProject(
            name: "demo",
            services: [ComposeService(name: "web", image: "nginx")],
            diagnostics: [
                ComposeDiagnostic(severity: .warning, path: "services.web.restart", message: "Unsupported restart policy.")
            ],
            sourcePath: "/tmp/demo/compose.yaml"
        )
        let commands = AppleContainerPlanner().planUp(project: project)

        let plan = AppleContainerPlan(project: project, operation: "up", commands: commands)
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(AppleContainerPlan.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, "1.8.0")
        XCTAssertEqual(decoded.projectName, "demo")
        XCTAssertEqual(decoded.sourcePath, "/tmp/demo/compose.yaml")
        XCTAssertEqual(decoded.runtime, "apple-container")
        XCTAssertEqual(decoded.executable, "container")
        XCTAssertNil(decoded.runtimeStatus)
        XCTAssertEqual(decoded.operation, "up")
        XCTAssertEqual(decoded.selectedServices, [])
        XCTAssertEqual(decoded.commands.map(\.action), [.runService])
        XCTAssertEqual(decoded.executionGraph?.schemaVersion, "1.1.0")
        XCTAssertEqual(decoded.executionGraph?.nodes.map(\.commandIndex), [0])
        XCTAssertEqual(decoded.diagnostics.first?.path, "services.web.restart")
    }

    func testAppleContainerPlanEnvelopeCanCarryRuntimeStatus() throws {
        let project = ComposeProject(
            name: "demo",
            services: [ComposeService(name: "web", image: "nginx")],
            sourcePath: "/tmp/demo/compose.yaml"
        )
        let runtimeStatus = AppleContainerRuntimeStatus(
            executablePath: "/opt/homebrew/bin/container",
            availability: .available,
            version: "container 1.2.3"
        )

        let plan = AppleContainerPlan(
            project: project,
            operation: "up",
            commands: AppleContainerPlanner().planUp(project: project),
            runtimeStatus: runtimeStatus
        )

        XCTAssertEqual(plan.schemaVersion, "1.8.0")
        XCTAssertEqual(plan.runtimeStatus, runtimeStatus)
    }

    func testAppleContainerPlanExecutionGraphCapturesDependsOnEdges() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", dependsOn: ["db"]),
                ComposeService(name: "db", image: "postgres")
            ],
            sourcePath: "compose.yaml"
        )
        let commands = AppleContainerPlanner().planUp(project: project)

        let plan = AppleContainerPlan(project: project, operation: "up", commands: commands)
        let graph = try XCTUnwrap(plan.executionGraph)

        XCTAssertEqual(graph.nodes.count, commands.count)
        XCTAssertEqual(graph.edges, [
            AppleContainerExecutionEdge(
                fromCommandIndex: 0,
                toCommandIndex: 1,
                dependencyMetadata: AppleContainerDependencyMetadata()
            )
        ])
        XCTAssertEqual(graph.nodes[1].dependsOnCommandIndexes, [0])
        XCTAssertEqual(graph.nodes[1].readiness, [])
    }

    func testAppleContainerPlanCanEmitReadinessRequirementsForDependsOnServices() throws {
        let project = ComposeProject(
            name: "Demo Project",
            services: [
                ComposeService(name: "web", image: "nginx", dependsOn: ["db"]),
                ComposeService(name: "db", image: "postgres", containerName: "database")
            ],
            sourcePath: "compose.yaml"
        )
        let commands = AppleContainerPlanner().planUp(project: project)

        let plan = AppleContainerPlan(
            project: project,
            operation: "up",
            commands: commands,
            emitReadinessChecks: true
        )
        let graph = try XCTUnwrap(plan.executionGraph)

        XCTAssertEqual(graph.nodes[1].readiness, [
            AppleContainerReadinessRequirement(service: "db", containerName: "database")
        ])
    }

    func testAppleContainerPlanGraphCapturesLongFormDependencyMetadata() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    dependsOn: ["db"],
                    dependsOnMetadata: [
                        "db": ComposeServiceDependencyMetadata(
                            condition: .serviceHealthy,
                            restart: true,
                            required: false
                        )
                    ]
                ),
                ComposeService(name: "db", image: "postgres")
            ],
            sourcePath: "compose.yaml"
        )
        let commands = AppleContainerPlanner().planUp(project: project)

        let plan = AppleContainerPlan(
            project: project,
            operation: "up",
            commands: commands,
            emitReadinessChecks: true
        )
        let graph = try XCTUnwrap(plan.executionGraph)

        XCTAssertEqual(graph.schemaVersion, "1.1.0")
        XCTAssertEqual(graph.edges.first?.dependencyMetadata, AppleContainerDependencyMetadata(
            condition: .serviceHealthy,
            restart: true,
            required: false
        ))
        XCTAssertEqual(graph.nodes[1].readiness, [
            AppleContainerReadinessRequirement(
                service: "db",
                condition: .healthy,
                containerName: "demo_db_1"
            )
        ])
    }

    func testAppleContainerPlanDecodesOlderJSONWithoutSelectedServices() throws {
        let json = """
        {
          "schemaVersion": "1.2.0",
          "projectName": "demo",
          "sourcePath": "/tmp/demo/compose.yaml",
          "runtime": "apple-container",
          "executable": "container",
          "operation": "up",
          "commands": [],
          "diagnostics": []
        }
        """

        let decoded = try JSONDecoder().decode(AppleContainerPlan.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.selectedServices, [])
        XCTAssertNil(decoded.executionGraph)
    }

    func testPlannedCommandDecodesOlderJSONWithoutOptionalCommandFields() throws {
        let json = """
        {
          "action": "runService",
          "service": "web",
          "arguments": ["run", "--name", "demo_web_1", "nginx"]
        }
        """

        let decoded = try JSONDecoder().decode(PlannedCommand.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.action, .runService)
        XCTAssertEqual(decoded.service, "web")
        XCTAssertEqual(decoded.arguments, ["run", "--name", "demo_web_1", "nginx"])
        XCTAssertEqual(decoded.diagnostics, [])
        XCTAssertEqual(decoded.generatedFiles, [])
    }

    func testPlanUpForSelectedServiceIncludesTransitiveDependenciesOnlyOnce() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", dependsOn: ["api"]),
                ComposeService(name: "api", image: "backend", dependsOn: ["cache", "db"]),
                ComposeService(name: "cache", image: "redis"),
                ComposeService(name: "db", image: "postgres"),
                ComposeService(name: "worker", image: "busybox", dependsOn: ["db"])
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planUp(project: project, services: ["web"])

        XCTAssertEqual(commands.filter { $0.action == .runService }.map(\.service), ["cache", "db", "api", "web"])
    }

    func testPlanUpForSelectedServiceIncludesNamespaceReferenceDependencies() throws {
        let yaml = """
        name: demo
        services:
          db:
            image: postgres
          sidecar:
            image: busybox
          web:
            image: nginx
            network_mode: service:db
            pid: service:sidecar
        """

        let project = try ComposeLoader().load(yaml: yaml)
        let commands = AppleContainerPlanner().planUp(project: project, services: ["web"])
        let runCommands = commands.filter { $0.action == .runService }

        XCTAssertEqual(runCommands.map(\.service), ["db", "sidecar", "web"])
        XCTAssertEqual(commands.first?.arguments, ["network", "create", "demo_default"])
        XCTAssertTrue(runCommands.last?.diagnostics.contains {
            $0.path == "services.web.network_mode"
            && $0.message.contains("not mapped")
        } == true)

        let plan = AppleContainerPlan(project: project, operation: "up", commands: commands)
        XCTAssertEqual(plan.executionGraph?.edges.filter { $0.toCommandIndex == 3 }.map(\.fromCommandIndex), [1, 2])
    }

    func testPlanUpForSelectedServicesScopesProjectResources() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "web",
                    image: "nginx",
                    volumes: ["web-data:/usr/share/nginx/html"],
                    networks: ["front"]
                ),
                ComposeService(
                    name: "worker",
                    image: "busybox",
                    volumes: ["worker-data:/data"],
                    networks: ["back"]
                )
            ],
            networks: [
                "front": ComposeNetwork(name: "front"),
                "back": ComposeNetwork(name: "back")
            ],
            volumes: [
                "web-data": ComposeVolume(name: "web-data"),
                "worker-data": ComposeVolume(name: "worker-data")
            ],
            sourcePath: "compose.yaml"
        )

        let commands = AppleContainerPlanner().planUp(project: project, services: ["web"])

        XCTAssertEqual(commands.filter { $0.action == .createNetwork }.compactMap(\.arguments.last), ["demo_front"])
        XCTAssertEqual(commands.filter { $0.action == .createVolume }.compactMap(\.arguments.last), ["demo_web-data"])
        XCTAssertEqual(commands.filter { $0.action == .runService }.map(\.service), ["web"])
    }
}
