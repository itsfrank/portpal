import Testing
@testable import PortpalCore

struct PortpalCoreTests {
    @Test func connectionDetailIncludesRetryDelay() {
        let status = ConnectionStatus(
            name: "postgres",
            sshHost: "box",
            localPort: 15432,
            remoteHost: "127.0.0.1",
            remotePort: 5432,
            autoStart: true,
            reconnectDelaySeconds: 10,
            processID: nil,
            processAlive: false,
            portReachable: false,
            state: .waitingToRetry,
            restartSuppressed: false,
            lastError: nil,
            nextRetryInSeconds: 9
        )

        #expect(status.detailText == "Retrying in 9s. box:15432 -> 127.0.0.1:5432")
    }

    @Test func failedConnectionDetailPrefersErrorMessage() {
        let status = ConnectionStatus(
            name: "postgres",
            sshHost: "box",
            localPort: 15432,
            remoteHost: "127.0.0.1",
            remotePort: 5432,
            autoStart: true,
            reconnectDelaySeconds: 10,
            processID: nil,
            processAlive: false,
            portReachable: false,
            state: .failed,
            restartSuppressed: false,
            lastError: "ssh process exited",
            nextRetryInSeconds: nil
        )

        #expect(status.detailText == "Failed: ssh process exited")
    }
}
