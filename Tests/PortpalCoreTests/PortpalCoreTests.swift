import Testing
import Foundation
@testable import PortpalCore

struct PortpalCoreTests {
    private func makeStatus(
        state: ConnectionState,
        lastError: String? = nil,
        nextRetryInSeconds: Int? = nil
    ) -> ConnectionStatus {
        ConnectionStatus(
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
            state: state,
            restartSuppressed: false,
            lastError: lastError,
            nextRetryInSeconds: nextRetryInSeconds
        )
    }

    @Test func connectionDetailIncludesRetryDelay() {
        let status = makeStatus(state: .waitingToRetry, nextRetryInSeconds: 9)

        #expect(status.detailText == "Retrying in 9s. box:15432 -> 127.0.0.1:5432")
    }

    @Test func failedConnectionDetailPrefersErrorMessage() {
        let status = makeStatus(state: .failed, lastError: "ssh process exited")

        #expect(status.detailText == "Failed: ssh process exited")
    }

    @Test func waitingToRetryWithoutDeadlineUsesFallbackText() {
        let status = makeStatus(state: .waitingToRetry)

        #expect(status.detailText == "Waiting to retry. box:15432 -> 127.0.0.1:5432")
    }

    @Test func failedConnectionWithoutErrorFallsBackToRouteDescription() {
        let status = makeStatus(state: .failed)

        #expect(status.detailText == "Failed. box:15432 -> 127.0.0.1:5432")
    }

    @Test func healthyAndStartingStatesDescribeCurrentPhase() {
        let healthy = makeStatus(state: .healthy)
        let starting = makeStatus(state: .starting)

        #expect(healthy.detailText == "box:15432 -> 127.0.0.1:5432")
        #expect(starting.detailText == "Starting. box:15432 -> 127.0.0.1:5432")
    }

    @Test func stoppedStateShowsStoppedPrefixAndDisplayNameMatchesName() {
        let status = makeStatus(state: .stopped)

        #expect(status.detailText == "Stopped. box:15432 -> 127.0.0.1:5432")
        #expect(status.displayName == "postgres")
        #expect(status.id == "postgres")
    }

    @Test func socketURLUsesConfigDirectory() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("portpal", isDirectory: true)
            .appendingPathComponent("portpal.sock")

        #expect(PortpalEnvironment.socketURL.path == expected.path)
    }

    @Test func connectionStatusDecodesWithoutExplicitID() throws {
        let json = """
        {
          "name": "postgres",
          "sshHost": "box",
          "localPort": 15432,
          "remoteHost": "127.0.0.1",
          "remotePort": 5432,
          "autoStart": true,
          "reconnectDelaySeconds": 10,
          "processID": null,
          "processAlive": false,
          "portReachable": false,
          "state": "healthy",
          "restartSuppressed": false,
          "lastError": null,
          "nextRetryInSeconds": null
        }
        """

        let status = try JSONDecoder().decode(ConnectionStatus.self, from: Data(json.utf8))

        #expect(status.id == "postgres")
        #expect(status.name == "postgres")
    }
}
