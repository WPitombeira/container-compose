import XCTest
@testable import ContainerComposeCore

final class EnvironmentResolverTests: XCTestCase {
    func testResolveTokenUsesDotEnvValueWhenProcessDoesNotDefineVariable() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let envFile = workdir.appendingPathComponent(".env")
        try "IMAGE=postgres:16\n".write(to: envFile, atomically: true, encoding: .utf8)

        let resolver = EnvironmentResolver(
            workingDirectoryURL: workdir,
            environment: [:]
        )
        let yaml = "services:\n  web:\n    image: ${IMAGE}"

        XCTAssertEqual(resolver.resolve(yaml), "services:\n  web:\n    image: postgres:16")
    }

    func testResolveTokenSupportsDefaultValues() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let resolver = EnvironmentResolver(
            workingDirectory: workdir.path,
            environment: ["EMPTY": ""]
        )

        let yaml = "${MISSING:-postgres}\n${EMPTY:-pg}\n${EMPTY-pg}"

        XCTAssertEqual(
            resolver.resolve(yaml),
            "postgres\npg\n"
        )
    }

    func testResolveSupportsUnbracedVariablesAndDollarEscaping() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let resolver = EnvironmentResolver(
            workingDirectory: workdir.path,
            environment: ["IMAGE": "nginx", "TAG_1": "alpine"]
        )

        let result = try resolver.resolveWithDiagnostics("$IMAGE:${TAG_1} $$IMAGE $")

        XCTAssertEqual(result.text, "nginx:alpine $IMAGE $")
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testResolveWarnsAndSubstitutesEmptyForUnsetVariables() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let resolver = EnvironmentResolver(workingDirectory: workdir.path, environment: [:])
        let result = try resolver.resolveWithDiagnostics("image: $IMAGE")

        XCTAssertEqual(result.text, "image: ")
        XCTAssertEqual(result.diagnostics.first?.severity, .warning)
        XCTAssertEqual(result.diagnostics.first?.path, "environment.IMAGE")
    }

    func testResolveSupportsRequiredVariables() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let resolver = EnvironmentResolver(
            workingDirectory: workdir.path,
            environment: ["EMPTY": "", "SET": "value"]
        )

        XCTAssertEqual(try resolver.resolveWithDiagnostics("${SET:?required}").text, "value")
        XCTAssertEqual(try resolver.resolveWithDiagnostics("${EMPTY?required}").text, "")

        XCTAssertThrowsError(try resolver.resolveWithDiagnostics("${EMPTY:?must set it}")) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Required environment variable EMPTY is not set: must set it"
            )
        }

        XCTAssertThrowsError(try resolver.resolveWithDiagnostics("${MISSING?must set it}")) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Required environment variable MISSING is not set: must set it"
            )
        }
    }

    func testResolveSupportsAlternateValues() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let resolver = EnvironmentResolver(
            workingDirectory: workdir.path,
            environment: ["EMPTY": "", "SET": "value"]
        )

        XCTAssertEqual(
            try resolver.resolveWithDiagnostics("${SET:+enabled}|${EMPTY:+enabled}|${EMPTY+enabled}|${MISSING+enabled}").text,
            "enabled||enabled|"
        )
    }

    func testResolveSupportsNestedExpressions() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let resolver = EnvironmentResolver(
            workingDirectory: workdir.path,
            environment: ["TAG": "alpine", "ERROR": "missing image"]
        )

        XCTAssertEqual(
            try resolver.resolveWithDiagnostics("${IMAGE:-nginx:${TAG:-latest}}").text,
            "nginx:alpine"
        )

        XCTAssertThrowsError(try resolver.resolveWithDiagnostics("${IMAGE:?${ERROR}}")) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Required environment variable IMAGE is not set: missing image"
            )
        }
    }

    func testResolvePreservesInvalidVariableSyntax() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let resolver = EnvironmentResolver(workingDirectory: workdir.path, environment: [:])

        XCTAssertEqual(
            try resolver.resolveWithDiagnostics("${1BAD} ${VAR/foo/bar} $-").text,
            "${1BAD} ${VAR/foo/bar} $-"
        )
    }

    func testResolveTokenUsesProcessEnvironmentBeforeDotEnv() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        let envFile = workdir.appendingPathComponent(".env")
        try "IMAGE=postgres:16\n".write(to: envFile, atomically: true, encoding: .utf8)

        let resolver = EnvironmentResolver(
            workingDirectoryURL: workdir,
            environment: ["IMAGE": "mysql:8"]
        )
        let yaml = "image: ${IMAGE:-default}"

        XCTAssertEqual(resolver.resolve(yaml), "image: mysql:8")
    }

    func testExplicitEnvFilesOverrideDotEnvInOrderButNotProcessEnvironment() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try "IMAGE=from-dot-env\nTAG=dot\n".write(
            to: workdir.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
        try "IMAGE=from-defaults\nTAG=defaults\n".write(
            to: workdir.appendingPathComponent("defaults.env"),
            atomically: true,
            encoding: .utf8
        )
        try "TAG=override\n".write(
            to: workdir.appendingPathComponent("local.env"),
            atomically: true,
            encoding: .utf8
        )

        let resolver = EnvironmentResolver(
            workingDirectoryURL: workdir,
            environment: ["IMAGE": "from-process"],
            envFiles: ["defaults.env", "local.env"]
        )

        XCTAssertEqual(resolver.resolve("${IMAGE}:${TAG}"), "from-process:override")
    }

    func testInterpolationEnvironmentUsesResolutionPrecedence() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try "IMAGE=from-dot-env\nTAG=dot\nDOT_ONLY=1\n".write(
            to: workdir.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
        try "IMAGE=from-defaults\nTAG=defaults\nDEFAULT_ONLY=1\n".write(
            to: workdir.appendingPathComponent("defaults.env"),
            atomically: true,
            encoding: .utf8
        )
        try "TAG=override\nLOCAL_ONLY=1\n".write(
            to: workdir.appendingPathComponent("local.env"),
            atomically: true,
            encoding: .utf8
        )

        let resolver = EnvironmentResolver(
            workingDirectoryURL: workdir,
            environment: ["IMAGE": "from-process", "PROCESS_ONLY": "1"],
            envFiles: ["defaults.env", "local.env"]
        )

        XCTAssertEqual(resolver.interpolationEnvironment, [
            "IMAGE": "from-process",
            "TAG": "override",
            "DEFAULT_ONLY": "1",
            "LOCAL_ONLY": "1",
            "PROCESS_ONLY": "1"
        ])
        XCTAssertNil(resolver.interpolationEnvironment["DOT_ONLY"])
    }

    private func makeTemporaryWorkdir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-resolver-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
