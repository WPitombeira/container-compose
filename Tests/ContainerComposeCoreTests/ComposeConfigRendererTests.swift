import XCTest
@testable import ContainerComposeCore

final class ComposeConfigRendererTests: XCTestCase {
    func testRendersPrettySortedJSON() throws {
        let text = try ComposeConfigRenderer().render(makeProject(), format: .json)

        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertTrue(text.contains(#""name" : "demo""#))
        XCTAssertTrue(text.contains(#""sourcePath" : "compose.yaml""#))
        XCTAssertTrue(text.contains(#""image" : "nginx:alpine""#))
    }

    func testRendersYAMLFromNormalizedProject() throws {
        let text = try ComposeConfigRenderer().render(makeProject(), format: .yaml)

        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertTrue(text.contains("name: demo"))
        XCTAssertTrue(text.contains("services:"))
        XCTAssertTrue(text.contains("image: nginx:alpine"))
        XCTAssertTrue(text.contains("initProcess: false"))
        XCTAssertTrue(text.contains("sourcePath: compose.yaml"))
    }

    func testParsesFormatCaseInsensitively() throws {
        XCTAssertEqual(try ComposeConfigRenderer.parseFormat("JSON"), .json)
        XCTAssertEqual(try ComposeConfigRenderer.parseFormat("yaml"), .yaml)
        XCTAssertThrowsError(try ComposeConfigRenderer.parseFormat("toml")) { error in
            XCTAssertEqual(error.localizedDescription, "Unsupported config format 'toml'. Expected one of: json, yaml.")
        }
    }

    private func makeProject() -> ComposeProject {
        ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "web", image: "nginx:alpine")
            ],
            sourcePath: "compose.yaml"
        )
    }
}
