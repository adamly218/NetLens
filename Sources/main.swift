import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct NetLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = Monitor(useLibproc: CommandLine.arguments.contains("--libproc"))
    @StateObject private var preferences = Preferences()
    @StateObject private var resolver = Resolver()
    @StateObject private var state = ViewState()

    var body: some Scene {
        Window("NetLens", id: "main") {
            ContentView(monitor: monitor, preferences: preferences, resolver: resolver, state: state)
        }
        .defaultSize(width: 1280, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .saveItem) {
                Button("Export as JSON…") { contentView.export(json: true) }
                    .keyboardShortcut("e")
                Button("Export as CSV…") { contentView.export(json: false) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Connections") {
                Button("Refresh") { monitor.refresh() }
                    .keyboardShortcut("r")
                Button(monitor.isPaused ? "Resume Updates" : "Pause Updates") {
                    monitor.isPaused.toggle()
                    monitor.objectWillChange.send()
                }
                .keyboardShortcut("p")
                Divider()
                Button("Expand All") { state.collapsed = [] }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Collapse All") { state.collapsed = Set(monitor.groups.map(\.pid)) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView(preferences: preferences)
        }
    }

    private var contentView: ContentView {
        ContentView(monitor: monitor, preferences: preferences, resolver: resolver, state: state)
    }
}

// MARK: - Command line

/// `--list` prints every socket grouped by process; add `--json` for JSON or `--libproc` to skip NetworkStatistics.
func printList(json: Bool, useLibproc: Bool) {
    let monitor = Monitor(useLibproc: useLibproc)
    monitor.refreshNow()
    if json {
        FileHandle.standardOutput.write(ExportRecord.json(ExportRecord.records(monitor.groups, resolver: nil)))
        print()
        return
    }
    let sockets = monitor.groups.reduce(0) { $0 + $1.connections.count }
    print("\(monitor.groups.count) processes, \(sockets) sockets (source: \(monitor.source))")
    for group in monitor.groups {
        print("\n\(group.name) (pid \(group.pid), \(group.signer.rawValue))")
        for connection in group.connections {
            let columns = [connection.proto.rawValue.padding(toLength: 4, withPad: " ", startingAt: 0),
                           connection.local.display.padding(toLength: 46, withPad: " ", startingAt: 0),
                           (connection.remote?.display ?? "*").padding(toLength: 46, withPad: " ", startingAt: 0),
                           connection.stateLabel.padding(toLength: 12, withPad: " ", startingAt: 0),
                           connection.interface ?? "-"]
            print("  " + columns.joined(separator: " "))
        }
    }
}

let arguments = CommandLine.arguments
if arguments.contains("--list") {
    printList(json: arguments.contains("--json"), useLibproc: arguments.contains("--libproc"))
} else {
    NetLensApp.main()
}
