import XCTest
@testable import ContainerComposeCore

final class ComposeCompatibilityTests: XCTestCase {
    func testCompatibilityMatrixContainsAllSupportTiers() {
        let matrix = ComposeCompatibilityMatrix.current
        let statuses = Set(matrix.entries.map(\.status))

        XCTAssertEqual(statuses, Set(ComposeCompatibilityStatus.allCases))
        XCTAssertTrue(matrix.entries.contains {
            $0.composePath == "services.*.deploy"
            && $0.status == .preservedDiagnostic
            && $0.note.contains("orchestration")
        })
        XCTAssertTrue(matrix.entries.contains {
            $0.composePath == "services.*.deploy.resources.reservations.generic_resources"
            && $0.status == .preservedDiagnostic
            && $0.note.contains("Generic resource")
        })
        XCTAssertTrue(matrix.entries.contains {
            $0.composePath == "services.*.deploy.update_config"
            && $0.status == .preservedDiagnostic
            && $0.note.contains("Rolling update")
        })
        XCTAssertTrue(matrix.entries.contains {
            $0.composePath == "services.*.extra_hosts"
            && $0.status == .preservedDiagnostic
        })
        XCTAssertTrue(matrix.entries.contains {
            $0.composePath == "services.*.privileged"
            && $0.status == .preservedDiagnostic
            && $0.note.contains("not mapped")
        })
        XCTAssertTrue(matrix.entries.contains {
            $0.composePath == "services.*.build.extra_hosts"
            && $0.status == .preservedDiagnostic
        })
        XCTAssertTrue(matrix.entries.contains {
            $0.composePath == "x-*"
            && $0.status == .mapped
        })
        XCTAssertTrue(matrix.entries.contains {
            $0.composePath == "unknown Compose fields"
            && $0.status == .unsupported
        })
    }

    func testCompatibilityMatrixFiltersByStatus() {
        let matrix = ComposeCompatibilityMatrix.current

        let preserved = matrix.entries(with: .preservedDiagnostic)

        XCTAssertFalse(preserved.isEmpty)
        XCTAssertTrue(preserved.allSatisfy { $0.status == .preservedDiagnostic })
        XCTAssertEqual(matrix.entries(with: nil), matrix.entries)
    }

    func testCompatibilityMatrixRendersAsJSONAndYAML() throws {
        let matrix = ComposeCompatibilityMatrix.current

        let json = try ComposeConfigRenderer().render(matrix, format: .json)
        let yaml = try ComposeConfigRenderer().render(matrix, format: .yaml)

        XCTAssertTrue(json.contains(#""composePath" : "services.*.image""#))
        XCTAssertTrue(json.contains(#""status" : "mapped""#))
        XCTAssertTrue(yaml.contains("composePath: services.*.image"))
        XCTAssertTrue(yaml.contains("generatedFrom: ContainerComposeCore support declarations"))
    }
}
