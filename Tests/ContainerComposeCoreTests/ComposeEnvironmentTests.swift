import XCTest
@testable import ContainerComposeCore

final class ComposeEnvironmentTests: XCTestCase {
    func testParsesComposeFilesUsingConfiguredPathSeparator() {
        let environment = ComposeEnvironment(environment: [
            "COMPOSE_FILE": "compose.yaml;compose.override.yaml;dev/docker-compose.yaml",
            "COMPOSE_PATH_SEPARATOR": ";"
        ])

        XCTAssertEqual(
            environment.composeFilePaths,
            ["compose.yaml", "compose.override.yaml", "dev/docker-compose.yaml"]
        )
    }

    func testParsesComposeFilesUsingDefaultPathSeparator() {
        let environment = ComposeEnvironment(environment: [
            "COMPOSE_FILE": "compose.yaml:compose.override.yaml"
        ])

#if os(Windows)
        XCTAssertEqual(environment.composeFilePaths, ["compose.yaml:compose.override.yaml"])
#else
        XCTAssertEqual(environment.composeFilePaths, ["compose.yaml", "compose.override.yaml"])
#endif
    }

    func testParsesComposeProfilesAsCommaSeparatedValues() {
        let environment = ComposeEnvironment(environment: [
            "COMPOSE_PROFILES": "debug, profiling,local"
        ])

        XCTAssertEqual(environment.composeProfiles, ["debug", "profiling", "local"])
    }

    func testParsesComposeProjectNameAsOptionalValue() {
        let withName = ComposeEnvironment(environment: [
            "COMPOSE_PROJECT_NAME": "  my-project  "
        ])
        XCTAssertEqual(withName.composeProjectName, "my-project")

        let withoutName = ComposeEnvironment(environment: [:])
        XCTAssertNil(withoutName.composeProjectName)

        let blankName = ComposeEnvironment(environment: [
            "COMPOSE_PROJECT_NAME": "   "
        ])
        XCTAssertNil(blankName.composeProjectName)
    }

    func testRemovesEmptySegmentsFromComposeFileAndProfilesValues() {
        let environment = ComposeEnvironment(environment: [
            "COMPOSE_FILE": "compose.yaml::compose.override.yaml::",
            "COMPOSE_PROFILES": ",debug,,local,"
        ])

        XCTAssertEqual(environment.composeFilePaths, ["compose.yaml", "compose.override.yaml"])
        XCTAssertEqual(environment.composeProfiles, ["debug", "local"])
    }
}
