import Testing
@testable import PortpalCore

@Test func aggregateHealthIsEmptyForNoTunnels() {
    #expect(AggregateHealth.from(statuses: []) == .empty)
}

@Test func aggregateHealthIsMixedForPartialFailures() {
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

    #expect(AggregateHealth.from(statuses: [healthy, unhealthy]) == .mixed)
}

@Test func tunnelValidationRejectsBadPorts() {
    let tunnel = TunnelSpec(sshHost: "box", localPort: 0, remoteHost: "127.0.0.1", remotePort: 22)

    #expect(throws: TunnelValidationError.invalidLocalPort(0)) {
        try tunnel.validate()
    }
}
