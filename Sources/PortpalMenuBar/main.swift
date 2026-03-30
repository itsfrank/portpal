import AppKit
import Combine
import SwiftUI
import PortpalCore

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published var snapshot = ServiceSnapshot(tunnels: [])
    @Published var formError: String?

    private let client = PortpalClient()

    init() {
        refresh()
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                refresh()
            }
        }
    }

    func refresh() {
        do {
            snapshot = try client.listTunnels()
            formError = nil
        } catch {
            formError = error.localizedDescription
        }
    }

    func createTunnel(name: String, sshHost: String, localPort: String, remoteHost: String, remotePort: String) {
        do {
            guard let localPort = Int(localPort), let remotePort = Int(remotePort) else {
                formError = "Ports must be numbers."
                return
            }

            let tunnel = TunnelSpec(name: name, sshHost: sshHost, localPort: localPort, remoteHost: remoteHost, remotePort: remotePort)
            _ = try client.createTunnel(tunnel)
            formError = nil
            refresh()
        } catch {
            formError = error.localizedDescription
        }
    }
}

struct TunnelRowView: View {
    let status: TunnelStatus

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(status.health == .healthy ? Color.green : Color.red)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.spec.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)

                Text("\(status.spec.remoteHost):\(status.spec.remotePort)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

struct MenuContentView: View {
    @EnvironmentObject private var model: MenuBarViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.snapshot.tunnels.isEmpty {
                Text("No managed tunnels")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(model.snapshot.tunnels) { status in
                    TunnelRowView(status: status)
                }
            }

            Divider()
                .padding(.vertical, 8)

            Button("Add Connection…") {
                openWindow(id: "add-connection")
            }
            .buttonStyle(.plain)

            Button("Refresh") {
                model.refresh()
            }
            .buttonStyle(.plain)

            Divider()
                .padding(.vertical, 8)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 280)
    }
}

struct AddConnectionView: View {
    @EnvironmentObject private var model: MenuBarViewModel
    @State private var name = ""
    @State private var sshHost = ""
    @State private var localPort = ""
    @State private var remoteHost = "127.0.0.1"
    @State private var remotePort = ""

    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("SSH Host", text: $sshHost)
            TextField("Local Port", text: $localPort)
            TextField("Remote Host", text: $remoteHost)
            TextField("Remote Port", text: $remotePort)
            if let error = model.formError {
                Text(error)
                    .foregroundStyle(.red)
            }
            Button("Add Connection") {
                model.createTunnel(name: name, sshHost: sshHost, localPort: localPort, remoteHost: remoteHost, remotePort: remotePort)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
        .frame(width: 320)
    }
}

enum StatusIconRenderer {
    static func image(for aggregateHealth: AggregateHealth) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size)
        image.isTemplate = false

        image.lockFocus()
        defer { image.unlockFocus() }

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
        let symbol = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "Portpal")?
            .withSymbolConfiguration(symbolConfig)

        if let symbol {
            let tinted = symbol.copy() as? NSImage ?? symbol
            tinted.isTemplate = false
            let symbolRect = NSRect(x: 1, y: 1, width: 14, height: 14)
            tinted.draw(in: symbolRect)
        }

        if let color = dotColor(for: aggregateHealth) {
            let dotRect = NSRect(x: 11, y: 9, width: 6, height: 6)
            let strokeRect = dotRect.insetBy(dx: -0.5, dy: -0.5)
            let strokePath = NSBezierPath(ovalIn: strokeRect)
            NSColor.windowBackgroundColor.setFill()
            strokePath.fill()

            let dotPath = NSBezierPath(ovalIn: dotRect)
            color.setFill()
            dotPath.fill()
        }

        return image
    }

    private static func dotColor(for aggregateHealth: AggregateHealth) -> NSColor? {
        switch aggregateHealth {
        case .empty:
            return NSColor.secondaryLabelColor
        case .allHealthy:
            return NSColor.systemGreen
        case .noneHealthy:
            return NSColor.systemRed
        case .mixed:
            return NSColor.systemYellow
        }
    }
}

@MainActor
final class StatusItemController: NSObject {
    private let model: MenuBarViewModel
    private let popover = NSPopover()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init(model: MenuBarViewModel) {
        self.model = model
        super.init()

        let hostingController = NSHostingController(rootView: MenuContentView().environmentObject(model))
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 280, height: 220)
        popover.contentViewController = hostingController

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        updateIcon()
    }

    func updateIcon() {
        statusItem.button?.image = StatusIconRenderer.image(for: model.snapshot.aggregateHealth)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else {
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            model.refresh()
            updateIcon()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let model = MenuBarViewModel()
    private var statusController: StatusItemController?
    private var observationTask: Task<Void, Never>?

    init() {
        statusController = StatusItemController(model: model)
    }

    func start() {
        NSApp.setActivationPolicy(.accessory)

        observationTask = Task {
            for await _ in model.$snapshot.values {
                statusController?.updateIcon()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppState.shared.start()
        }
    }
}

@main
struct PortpalMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        WindowGroup("Add Connection", id: "add-connection") {
            AddConnectionView()
                .environmentObject(state.model)
        }
        .defaultSize(width: 320, height: 260)

        Settings {
            EmptyView()
        }
    }
}
