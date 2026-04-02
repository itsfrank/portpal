import AppKit
import Combine
import SwiftUI
import PortpalCore

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published var snapshot = ServiceSnapshot(connections: [], aggregateHealth: .empty)
    @Published var errorMessage: String?

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
            snapshot = try client.listConnections()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadConfig() {
        do {
            snapshot = try client.reloadConfig()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshConnection(named name: String) {
        do {
            _ = try client.refreshConnection(named: name)
            errorMessage = nil
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopConnection(named name: String) {
        do {
            _ = try client.stopConnection(named: name)
            errorMessage = nil
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ConnectionRowView: View {
    @EnvironmentObject private var model: MenuBarViewModel

    let status: ConnectionStatus

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)

                Text(status.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                model.refreshConnection(named: status.name)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Restart connection")

            Button {
                model.stopConnection(named: status.name)
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.plain)
            .help("Stop connection")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private var dotColor: Color {
        switch status.state {
        case .healthy:
            return .green
        case .starting:
            return .yellow
        case .waitingToRetry:
            return .red
        case .stopped:
            return .gray
        case .failed:
            return .red
        }
    }
}

struct MenuContentView: View {
    @EnvironmentObject private var model: MenuBarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 8)
            }

            if model.snapshot.connections.isEmpty {
                Text("No configured connections")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(model.snapshot.connections) { status in
                    ConnectionRowView(status: status)
                }
            }

            Divider()
                .padding(.vertical, 8)

            Button("Reload Config") {
                model.reloadConfig()
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
        .frame(width: 360)
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

    func start() {
        NSApp.setActivationPolicy(.accessory)
        statusController = StatusItemController(model: model)

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
        Settings {
            EmptyView()
        }
    }
}
