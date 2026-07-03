import XCTest
@testable import ContainerComposeCore

final class ComposeConfigProjectionTests: XCTestCase {
    func testProjectsServicesInNormalizedModelOrder() {
        let project = makeProject()

        XCTAssertEqual(
            ComposeConfigProjection.values(for: .services, in: project),
            ["api", "worker", "web"]
        )
    }

    func testProjectsUniqueImagesInServiceOrder() {
        let project = makeProject()

        XCTAssertEqual(
            ComposeConfigProjection.values(for: .images, in: project),
            ["example/api:dev", "busybox:latest"]
        )
    }

    func testProjectsProfilesNetworksAndVolumesDeterministically() {
        let project = makeProject()

        XCTAssertEqual(ComposeConfigProjection.values(for: .profiles, in: project), ["debug", "jobs"])
        XCTAssertEqual(ComposeConfigProjection.values(for: .networks, in: project), ["back", "front"])
        XCTAssertEqual(ComposeConfigProjection.values(for: .volumes, in: project), ["cache", "db-data"])
    }

    func testProjectionEnvelopeCarriesModeAndValues() {
        let project = makeProject()
        let projection = ComposeConfigProjection.project(project, mode: .images)

        XCTAssertEqual(projection.mode, .images)
        XCTAssertEqual(projection.values, ["example/api:dev", "busybox:latest"])
    }

    private func makeProject() -> ComposeProject {
        ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "api", image: "example/api:dev", profiles: ["debug"]),
                ComposeService(name: "worker", image: "busybox:latest", profiles: ["jobs", "debug"]),
                ComposeService(name: "web", image: "example/api:dev")
            ],
            networks: [
                "front": ComposeNetwork(name: "front"),
                "back": ComposeNetwork(name: "back")
            ],
            volumes: [
                "db-data": ComposeVolume(name: "db-data"),
                "cache": ComposeVolume(name: "cache")
            ],
            sourcePath: "compose.yaml"
        )
    }
}
