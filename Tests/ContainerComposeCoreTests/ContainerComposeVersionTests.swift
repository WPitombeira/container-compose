import XCTest
@testable import ContainerComposeCore

final class ContainerComposeVersionTests: XCTestCase {
    func testCurrentVersionInfoExposesIntegrationAndSchemaVersions() {
        let info = ContainerComposeMetadata.currentVersionInfo

        XCTAssertEqual(info.name, "Container Compose")
        XCTAssertEqual(info.packageName, "ContainerCompose")
        XCTAssertEqual(info.commandName, "container-compose")
        XCTAssertEqual(info.version, "0.1.0")
        XCTAssertEqual(info.runtimeTarget, "apple-container")
        XCTAssertEqual(info.containerDesktopIntegration, "ContainerComposeCore")
        XCTAssertEqual(info.schemas.plan, "1.8.0")
        XCTAssertEqual(info.schemas.executionReport, "1.8.0")
        XCTAssertEqual(info.schemas.executionGraph, "1.1.0")
        XCTAssertEqual(info.schemas.runtimeStatus, "1.0.0")
    }

    func testSchemaConstantsMatchPublicEnvelopeDefaults() {
        let project = ComposeProject(name: "versions", services: [], sourcePath: "/tmp/compose.yaml")
        let plan = AppleContainerPlan(project: project, operation: "plan", commands: [])
        let report = AppleContainerExecutionReport(plan: plan, dryRun: true, results: [])
        let graph = AppleContainerExecutionGraph(nodes: [], edges: [])
        let runtime = AppleContainerRuntimeStatus(availability: .available)

        XCTAssertEqual(plan.schemaVersion, ContainerComposeMetadata.planSchemaVersion)
        XCTAssertEqual(report.schemaVersion, ContainerComposeMetadata.executionReportSchemaVersion)
        XCTAssertEqual(graph.schemaVersion, ContainerComposeMetadata.executionGraphSchemaVersion)
        XCTAssertEqual(runtime.schemaVersion, ContainerComposeMetadata.runtimeStatusSchemaVersion)
    }

    func testVersionInfoRendersAsMachineReadableJSONAndYAML() throws {
        let info = ContainerComposeMetadata.currentVersionInfo

        let json = try ComposeConfigRenderer().render(info, format: .json)
        let yaml = try ComposeConfigRenderer().render(info, format: .yaml)

        XCTAssertTrue(json.contains(#""commandName" : "container-compose""#))
        XCTAssertTrue(json.contains(#""plan" : "1.8.0""#))
        XCTAssertTrue(yaml.contains("commandName: container-compose"))
        XCTAssertTrue(yaml.contains("plan: 1.8.0"))
    }
}
