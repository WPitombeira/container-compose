import XCTest
@testable import ContainerComposeCore

final class ComposePortResolverTests: XCTestCase {
    func testResolvesShortSyntaxPublishedPort() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", ports: ["8080:80"])
            ],
            sourcePath: "compose.yaml"
        )

        let resolution = try ComposePortResolver().resolve(project: project, serviceName: "web", privatePort: "80")

        XCTAssertEqual(resolution.endpoint, "0.0.0.0:8080")
        XCTAssertEqual(resolution.publishedPort, "8080")
        XCTAssertEqual(resolution.privatePort, "80")
        XCTAssertEqual(resolution.protocolValue, "tcp")
        XCTAssertNil(resolution.hostIP)
        XCTAssertEqual(resolution.diagnostics, [])
    }

    func testResolvesHostIPAndProtocol() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", ports: ["127.0.0.1:9000:90/udp"])
            ],
            sourcePath: "compose.yaml"
        )

        let resolution = try ComposePortResolver().resolve(
            project: project,
            serviceName: "web",
            privatePort: "90",
            protocolValue: "udp"
        )

        XCTAssertEqual(resolution.endpoint, "127.0.0.1:9000")
        XCTAssertEqual(resolution.hostIP, "127.0.0.1")
        XCTAssertEqual(resolution.protocolValue, "udp")
    }

    func testResolvesMatchingPortRangeOffset() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", ports: ["8000-8002:80-82"])
            ],
            sourcePath: "compose.yaml"
        )

        let resolution = try ComposePortResolver().resolve(project: project, serviceName: "web", privatePort: "81")

        XCTAssertEqual(resolution.endpoint, "0.0.0.0:8001")
    }

    func testReplicaIndexAddsStaticResolutionDiagnostic() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", ports: ["8080:80"])
            ],
            sourcePath: "compose.yaml"
        )

        let resolution = try ComposePortResolver().resolve(
            project: project,
            serviceName: "web",
            privatePort: "80",
            replicaIndex: 2
        )

        XCTAssertEqual(resolution.endpoint, "0.0.0.0:8080")
        XCTAssertEqual(resolution.diagnostics.map(\.path), ["port.index"])
    }

    func testThrowsWhenServiceDoesNotPublishRequestedPort() {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx", ports: ["8080:80"])
            ],
            sourcePath: "compose.yaml"
        )

        XCTAssertThrowsError(try ComposePortResolver().resolve(project: project, serviceName: "web", privatePort: "443")) { error in
            XCTAssertEqual(
                error as? ComposePortResolutionError,
                .publishedPortNotFound(service: "web", privatePort: "443", protocolValue: "tcp")
            )
        }
    }
}
