import XCTest
@testable import ContainerComposeCore

final class ComposeResourceKeysTests: XCTestCase {
    private let sut = ComposeResourceKeys()

    func testComputesStablePortKeyFromShortPortSyntaxWithIpTargetPublishedAndProtocol() {
        let key = sut.portMergeKey(from: "127.0.0.1:8080:80/tcp")

        XCTAssertEqual(key, "ip=127.0.0.1;target=80;published=8080;protocol=tcp")
    }

    func testComputesStablePortKeyFromShortPortSyntaxWithoutIp() {
        let key = sut.portMergeKey(from: "8080:80")

        XCTAssertEqual(key, "target=80;published=8080;protocol=tcp")
    }

    func testComputesStablePortKeyFromLongPortMapSyntax() {
        let key = sut.portMergeKey(from: [
            "target": 80,
            "published": 8080,
            "protocol": "TCP",
            "host_ip": "127.0.0.1"
        ])

        XCTAssertEqual(key, "ip=127.0.0.1;target=80;published=8080;protocol=tcp")
    }

    func testComputesStableVolumeKeyFromShortVolumeSyntaxTargetedByContainerPath() {
        let key = sut.volumeMergeKey(from: "db-data:/var/lib/postgresql/data:rw")

        XCTAssertEqual(key, "/var/lib/postgresql/data")
    }

    func testComputesStableVolumeKeyFromLongVolumeMapUsingTargetPath() {
        let key = sut.volumeMergeKey(from: [
            "type": "volume",
            "source": "db-data",
            "target": "/var/lib/postgresql/data"
        ])

        XCTAssertEqual(key, "/var/lib/postgresql/data")
    }

    func testFallsBackToSingleValueWhenVolumeTargetMissing() {
        let key = sut.volumeMergeKey(from: "/var/lib/postgresql/data")

        XCTAssertEqual(key, "/var/lib/postgresql/data")
    }

    func testComputesConfigAndSecretKeysFromEffectiveTargets() {
        XCTAssertEqual(sut.configMergeKey(from: "app-config"), "/app-config")
        XCTAssertEqual(sut.secretMergeKey(from: "db-password"), "/run/secrets/db-password")

        XCTAssertEqual(sut.configMergeKey(from: [
            "source": "app-config",
            "target": "/etc/app/config.yml"
        ]), "/etc/app/config.yml")
        XCTAssertEqual(sut.secretMergeKey(from: [
            "source": "db-password",
            "target": "password"
        ]), "/run/secrets/password")
    }

    func testReturnsNilForUnsupportedResourceValue() {
        XCTAssertNil(sut.portMergeKey(from: 123))
        XCTAssertNil(sut.volumeMergeKey(from: [1: "value"]))
        XCTAssertNil(sut.configMergeKey(from: 123))
        XCTAssertNil(sut.secretMergeKey(from: [1: "value"]))
    }
}
