import XCTest
@testable import ContainerComposeCore

final class ComposeProjectFilterTests: XCTestCase {
    func testFiltersSelectedServicesWithDependenciesAndUsedResources() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(
                    name: "db",
                    image: "postgres:16",
                    volumes: ["db-data:/var/lib/postgresql/data"],
                    networks: ["default"]
                ),
                ComposeService(
                    name: "web",
                    image: "nginx:alpine",
                    volumes: ["./public:/usr/share/nginx/html:ro"],
                    networks: ["front"],
                    modelGrants: [ComposeServiceModelGrant(name: "llm")],
                    dependsOn: ["db"],
                    configs: [ComposeServiceResourceGrant(source: "web-config", target: "/etc/web/config.yml")],
                    secrets: [ComposeServiceResourceGrant(source: "web-secret", target: "/run/secrets/web")]
                ),
                ComposeService(
                    name: "worker",
                    image: "busybox",
                    volumes: ["worker-cache:/cache"],
                    networks: ["back"]
                )
            ],
            networks: [
                "default": ComposeNetwork(name: "default"),
                "front": ComposeNetwork(name: "front"),
                "back": ComposeNetwork(name: "back")
            ],
            volumes: [
                "db-data": ComposeVolume(name: "db-data"),
                "worker-cache": ComposeVolume(name: "worker-cache")
            ],
            configs: [
                "web-config": ComposeConfig(name: "web-config", file: "./web.yml"),
                "unused-config": ComposeConfig(name: "unused-config", file: "./unused.yml")
            ],
            secrets: [
                "web-secret": ComposeSecret(name: "web-secret", file: "./secret"),
                "unused-secret": ComposeSecret(name: "unused-secret", file: "./unused-secret")
            ],
            models: [
                "llm": ComposeModelDefinition(name: "llm", model: "ai/smollm2"),
                "unused-model": ComposeModelDefinition(name: "unused-model", model: "ai/unused")
            ],
            sourcePath: "compose.yaml"
        )

        let filtered = ComposeProjectFilter().filter(project, selectedServices: ["web"])

        XCTAssertEqual(filtered.services.map(\.name), ["db", "web"])
        XCTAssertEqual(Set(filtered.networks.keys), ["default", "front"])
        XCTAssertEqual(Set(filtered.volumes.keys), ["db-data"])
        XCTAssertEqual(Set(filtered.configs.keys), ["web-config"])
        XCTAssertEqual(Set(filtered.secrets.keys), ["web-secret"])
        XCTAssertEqual(Set(filtered.models.keys), ["llm"])
        XCTAssertTrue(filtered.diagnostics.isEmpty)
    }

    func testMissingSelectedServiceProducesDiagnostic() {
        let project = ComposeProject(
            name: "demo",
            services: [ComposeService(name: "web", image: "nginx")],
            sourcePath: "compose.yaml"
        )

        let filtered = ComposeProjectFilter().filter(project, selectedServices: ["missing"])

        XCTAssertTrue(filtered.services.isEmpty)
        XCTAssertTrue(filtered.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.missing"
            && $0.message.contains("Selected service")
        })
    }
}
