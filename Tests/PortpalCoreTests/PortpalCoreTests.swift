import XCTest
@testable import PortpalCore

final class PortpalCoreTests: XCTestCase {
    func testAggregateHealthIsEmptyForNoTunnels() {
        XCTAssertEqual(AggregateHealth.from(statuses: []), .empty)
    }

    func testAggregateHealthIsMixedForPartialFailures() {
        let healthy = TunnelStatus(
            spec: TunnelSpec(sshHost: "box-a", localPort: 9001, remoteHost: "127.0.0.1", remotePort: 22),
            isManaged: true,
            processID: 1,
            processAlive: true,
            portReachable: true,
            lastCheckedAt: nil
        )
        let unhealthy = TunnelStatus(
            spec: TunnelSpec(sshHost: "box-b", localPort: 9002, remoteHost: "127.0.0.1", remotePort: 22),
            isManaged: true,
            processID: 2,
            processAlive: true,
            portReachable: false,
            lastCheckedAt: nil
        )

        XCTAssertEqual(AggregateHealth.from(statuses: [healthy, unhealthy]), .mixed)
    }

    func testTunnelValidationRejectsBadPorts() {
        let tunnel = TunnelSpec(sshHost: "box", localPort: 0, remoteHost: "127.0.0.1", remotePort: 22)

        XCTAssertThrowsError(try tunnel.validate()) { error in
            XCTAssertEqual(error as? TunnelValidationError, TunnelValidationError.invalidLocalPort(0))
        }
    }

    func testRemovalNameMatchesExplicitName() {
        let tunnel = TunnelSpec(name: "postgres", sshHost: "box", localPort: 5432, remoteHost: "127.0.0.1", remotePort: 5432)

        XCTAssertTrue(tunnel.matchesRemovalName("postgres"))
    }

    func testRemovalNameFallsBackToDisplayName() {
        let tunnel = TunnelSpec(sshHost: "box", localPort: 5432, remoteHost: "127.0.0.1", remotePort: 5432)

        XCTAssertTrue(tunnel.matchesRemovalName("box:5432"))
    }
}
