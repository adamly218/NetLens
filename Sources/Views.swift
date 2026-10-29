import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Scope: String, CaseIterable, Identifiable {
    case all = "All"
    case connected = "Connected"
    case listening = "Listening"
    var id: String { rawValue }
}

enum ProtoFilter: String, CaseIterable, Identifiable {
    case both = "TCP and UDP"
    case tcp = "TCP only"
    case udp = "UDP only"
    var id: String { rawValue }
}

/// UI state that SwiftUI's `@State` would normally hold.
final class ViewState: ObservableObject {
    @Published var search = ""
    @Published var scope = Scope.all
    @Published var proto = ProtoFilter.both
    @Published var selection: Set<Row.ID> = []
    @Published var collapsed: Set<pid_t> = []

    func expansion(_ pid: pid_t) -> Binding<Bool> {
        Binding { !self.collapsed.contains(pid) } set: { open in
            if open { self.collapsed.remove(pid) } else { self.collapsed.insert(pid) }
        }
    }
}

enum Row: Identifiable, Hashable {
    case process(ProcessGroup)
    case connection(Connection, ProcessGroup)

    var id: String {
        switch self {
        case .process(let group): return "process-\(group.pid)"
        case .connection(let connection, _): return connection.id
        }
    }

    var group: ProcessGroup {
        switch self {
        case .process(let group), .connection(_, let group): return group
        }
    }
}

extension Signer {
    var color: Color {
        switch self {
        case .apple: return .gray
        case .appStore: return .blue
        case .developerID: return .green
        case .signed, .adHoc: return .orange
        case .unsigned, .invalid, .unknown: return .red
        }
    }
}

// MARK: - Filtering and export

struct Filtered {
    var groups: [ProcessGroup]

    init(_ groups: [ProcessGroup], preferences: Preferences, state: ViewState, resolver: Resolver) {
        let query = state.search.trimmingCharacters(in: .whitespaces).lowercased()
        self.groups = groups.compactMap { group in
            if preferences.hiddenProcesses.contains(group.name) { return nil }
            if preferences.hideApple, group.signer == .apple { return nil }
            let nameMatches = query.isEmpty || group.name.lowercased().contains(query) || String(group.pid) == query
            var copy = group
            copy.connections = group.connections.filter { connection in
                if preferences.hideLocal, connection.isLocalOnly { return false }
                switch state.scope {
                case .all: break
                case .connected: if connection.remote == nil { return false }
                case .listening: if !connection.isListening { return false }
                }
                switch state.proto {
                case .both: break
                case .tcp: if connection.proto != .tcp { return false }
                case .udp: if connection.proto != .udp { return false }
                }
                if nameMatches { return true }
                let text = [connection.local.display, connection.remote?.display ?? "", connection.stateLabel,
                            connection.proto.rawValue, connection.interface ?? "",
                            connection.remote.flatMap { resolver.name(for: $0.address) } ?? ""]
                    .joined(separator: " ").lowercased()
                return text.contains(query)
            }
            return copy.connections.isEmpty ? nil : copy
        }
    }

    var connectionCount: Int { groups.reduce(0) { $0 + $1.connections.count } }
    var listeningCount: Int { groups.reduce(0) { $0 + $1.listeningCount } }
    var rxRate: Double { groups.reduce(0) { $0 + ($1.rxRate ?? 0) } }
    var txRate: Double { groups.reduce(0) { $0 + ($1.txRate ?? 0) } }
}

struct ExportRecord: Codable {
    var process: String
    var pid: Int32
    var path: String?
    var signer: String
    var proto: String
    var local: String
    var remote: String?
    var remoteHost: String?
    var state: String
    var interface: String?
    var bytesReceived: UInt64?
    var bytesSent: UInt64?

    static func records(_ groups: [ProcessGroup], resolver: Resolver?) -> [ExportRecord] {
        groups.flatMap { group in
            group.connections.map { connection in
                ExportRecord(process: group.name, pid: group.pid, path: group.path, signer: group.signer.rawValue,
                             proto: connection.proto.rawValue, local: connection.local.display,
                             remote: connection.remote?.display,
                             remoteHost: connection.remote.flatMap { resolver?.name(for: $0.address) },
                             state: connection.stateLabel, interface: connection.interface,
                             bytesReceived: connection.rxBytes, bytesSent: connection.txBytes)
            }
        }
    }

    static func json(_ records: [ExportRecord]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(records)) ?? Data()
    }

    static func csv(_ records: [ExportRecord]) -> Data {
        func field(_ value: String?) -> String {
            let text = value ?? ""
            return text.contains(where: { ",\"\n".contains($0) }) ? "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\"" : text
        }
        let header = "process,pid,path,signer,protocol,local,remote,remote_host,state,interface,bytes_received,bytes_sent"
        let lines = records.map { record in
            [field(record.process), String(record.pid), field(record.path), record.signer, record.proto,
             field(record.local), field(record.remote), field(record.remoteHost), field(record.state),
             field(record.interface), record.bytesReceived.map(String.init) ?? "", record.bytesSent.map(String.init) ?? ""]
                .joined(separator: ",")
        }
        return ([header] + lines).joined(separator: "\n").appending("\n").data(using: .utf8) ?? Data()
    }
}

// MARK: - Main window

struct ContentView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var preferences: Preferences
    @ObservedObject var resolver: Resolver
    @ObservedObject var state: ViewState

    private var filtered: Filtered {
        Filtered(monitor.groups, preferences: preferences, state: state, resolver: resolver)
    }

    var body: some View {
        let filtered = self.filtered
        VStack(spacing: 0) {
            table(filtered)
            Divider()
            statusBar(filtered)
        }
        .frame(minWidth: 980, minHeight: 520)
        .searchable(text: $state.search, placement: .toolbar, prompt: "Process, address, port, host")
        .toolbar { toolbar }
        .onReceive(monitor.$lastUpdate) { _ in lookUpNames() }
        .onChange(of: preferences.resolveNames) { _, _ in lookUpNames() }
        .onChange(of: preferences.interval) { _, value in monitor.interval = value }
        .onAppear {
            monitor.interval = preferences.interval
            monitor.start()
        }
    }

    private func lookUpNames() {
        guard preferences.resolveNames else { return }
        for group in monitor.groups {
            for connection in group.connections {
                if let remote = connection.remote, !remote.isLoopback, !remote.isUnspecified {
                    resolver.lookUp(remote.address)
                }
            }
        }
    }

    // MARK: Table

    private func table(_ filtered: Filtered) -> some View {
        Table(of: Row.self, selection: $state.selection) {
            TableColumn("Process / Connection") { row in nameCell(row) }
                .width(min: 200, ideal: 250)
            TableColumn("Protocol") { row in
                if case .connection(let connection, _) = row {
                    Text(connection.proto.rawValue).foregroundStyle(connection.proto == .tcp ? .blue : .purple)
                }
            }
            .width(56)
            TableColumn("Local") { row in
                if case .connection(let connection, _) = row {
                    Text(preferences.display(connection.local)).monospacedDigit()
                }
            }
            .width(min: 110, ideal: 150)
            TableColumn("Remote") { row in
                if case .connection(let connection, _) = row {
                    Text(connection.remote.map { preferences.display($0) } ?? "–").monospacedDigit()
                }
            }
            .width(min: 110, ideal: 170)
            TableColumn("State") { row in stateCell(row) }
                .width(min: 80, ideal: 96)
            TableColumn("Interface") { row in
                if case .connection(let connection, _) = row { Text(connection.interface ?? "–").foregroundStyle(.secondary) }
            }
            .width(64)
            TableColumn("Download") { row in Text(Format.rate(rxRate(row))).monospacedDigit() }
                .width(min: 70, ideal: 80)
            TableColumn("Upload") { row in Text(Format.rate(txRate(row))).monospacedDigit() }
                .width(min: 70, ideal: 80)
            TableColumn("Received") { row in Text(Format.bytes(rxBytes(row))).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 70, ideal: 80)
            TableColumn("Sent") { row in Text(Format.bytes(txBytes(row))).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 70, ideal: 80)
        } rows: {
            ForEach(filtered.groups) { group in
                DisclosureTableRow(Row.process(group), isExpanded: state.expansion(group.pid)) {
                    ForEach(group.connections) { connection in
                        TableRow(Row.connection(connection, group))
                    }
                }
            }
        }
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            contextMenu(for: ids, in: filtered)
        }
        .overlay {
            if filtered.groups.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "network").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(monitor.lastUpdate == nil ? "Loading connections…" : "No matching connections")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func nameCell(_ row: Row) -> some View {
        switch row {
        case .process(let group):
            HStack(spacing: 6) {
                Image(nsImage: group.icon).resizable().frame(width: 16, height: 16)
                Text(group.name).fontWeight(.medium).lineLimit(1)
                Text(verbatim: String(group.pid)).foregroundStyle(.secondary).monospacedDigit()
                Text(group.signer.rawValue)
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .foregroundStyle(group.signer.color)
                    .background(group.signer.color.opacity(0.15), in: Capsule())
            }
            .help(group.path ?? group.name)
        case .connection(let connection, _):
            if let remote = connection.remote {
                Label(preferences.host(remote, resolver: resolver), systemImage: "arrow.left.arrow.right")
                    .lineLimit(1).truncationMode(.middle)
            } else if connection.isListening {
                Label("Listening on port " + String(connection.local.port), systemImage: "ear")
                    .foregroundStyle(.orange)
            } else {
                Label("Not connected", systemImage: "circle.dashed").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func stateCell(_ row: Row) -> some View {
        switch row {
        case .process(let group):
            Text("\(group.connections.count) socket\(group.connections.count == 1 ? "" : "s")").foregroundStyle(.secondary)
        case .connection(let connection, _):
            Text(connection.stateLabel)
                .foregroundStyle(connection.stateLabel == "Established" || connection.stateLabel == "Connected" ? .green
                                 : connection.isListening ? .orange : .secondary)
        }
    }

    private func rxRate(_ row: Row) -> Double? {
        if case .connection(let connection, _) = row { return connection.rxRate }
        return row.group.rxRate
    }

    private func txRate(_ row: Row) -> Double? {
        if case .connection(let connection, _) = row { return connection.txRate }
        return row.group.txRate
    }

    private func rxBytes(_ row: Row) -> Double? {
        if case .connection(let connection, _) = row { return connection.rxBytes.map { Double($0) } }
        return row.group.rxBytes
    }

    private func txBytes(_ row: Row) -> Double? {
        if case .connection(let connection, _) = row { return connection.txBytes.map { Double($0) } }
        return row.group.txBytes
    }

    // MARK: Context menu

    @ViewBuilder private func contextMenu(for ids: Set<Row.ID>, in filtered: Filtered) -> some View {
        let rows = filtered.groups.flatMap { group in
            [Row.process(group)] + group.connections.map { Row.connection($0, group) }
        }.filter { ids.contains($0.id) }

        if !rows.isEmpty {
            Button("Copy") { copy(rows.map(describe).joined(separator: "\n")) }
            let remotes = rows.compactMap { row -> String? in
                if case .connection(let connection, _) = row { return connection.remote?.address }
                return nil
            }
            if !remotes.isEmpty {
                Button("Copy Remote Address") { copy(remotes.joined(separator: "\n")) }
            }
            if rows.count == 1, let group = rows.first?.group {
                Divider()
                if let path = group.path {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: group.iconPath ?? path)])
                    }
                }
                Button("Hide “\(group.name)”") { preferences.hiddenProcesses.append(group.name) }
                Button("Quit “\(group.name)”…") { quit(group) }
            }
        }
    }

    private func describe(_ row: Row) -> String {
        switch row {
        case .process(let group):
            return "\(group.name) (pid \(group.pid)) \(group.path ?? "")"
        case .connection(let connection, let group):
            return [group.name, connection.proto.rawValue, preferences.display(connection.local),
                    connection.remote.map { preferences.display($0) } ?? "*", connection.stateLabel]
                .joined(separator: "  ")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func quit(_ group: ProcessGroup) {
        let alert = NSAlert()
        alert.messageText = "Quit \(group.name)?"
        alert.informativeText = group.signer == .apple
            ? "This is part of macOS. It may restart on its own, and quitting it can affect system features."
            : "Unsaved work in \(group.name) may be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let app = NSRunningApplication(processIdentifier: group.pid), app.terminate() {
        } else if kill(group.pid, SIGTERM) != 0 {
            let failure = NSAlert()
            failure.messageText = "Couldn't quit \(group.name)"
            failure.informativeText = String(cString: strerror(errno))
            failure.runModal()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { monitor.refresh() }
    }

    // MARK: Toolbar and status bar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Show", selection: $state.scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarItemGroup {
            Menu {
                Picker("Protocol", selection: $state.proto) {
                    ForEach(ProtoFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Hide Apple Processes", isOn: $preferences.hideApple)
                Toggle("Hide Localhost Traffic", isOn: $preferences.hideLocal)
                Toggle("Look Up Host Names", isOn: $preferences.resolveNames)
                Toggle("Mask Addresses", isOn: $preferences.maskAddresses)
                if !preferences.hiddenProcesses.isEmpty {
                    Divider()
                    Button("Show Hidden Processes (\(preferences.hiddenProcesses.count))") { preferences.hiddenProcesses = [] }
                }
            } label: {
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("Filters")

            Button { monitor.isPaused.toggle(); monitor.objectWillChange.send() } label: {
                Label(monitor.isPaused ? "Resume" : "Pause", systemImage: monitor.isPaused ? "play.fill" : "pause.fill")
            }
            .help(monitor.isPaused ? "Resume live updates" : "Pause live updates")

            Button { monitor.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Refresh now (⌘R)")

            Menu {
                Button("Export as JSON…") { export(json: true) }
                Button("Export as CSV…") { export(json: false) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export the connections shown")
        }
    }

    private func statusBar(_ filtered: Filtered) -> some View {
        HStack(spacing: 14) {
            Text("\(filtered.groups.count) processes")
            Text("\(filtered.connectionCount) sockets")
            Label("\(filtered.listeningCount) listening", systemImage: "ear").foregroundStyle(.orange)
            Spacer()
            Label(Format.rate(filtered.rxRate), systemImage: "arrow.down").foregroundStyle(.teal)
            Label(Format.rate(filtered.txRate), systemImage: "arrow.up").foregroundStyle(.pink)
            if monitor.isPaused {
                Text("Paused").foregroundStyle(.orange)
            } else if let lastUpdate = monitor.lastUpdate {
                Text("Updated \(lastUpdate.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11.5))
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    func export(json: Bool) {
        let records = ExportRecord.records(filtered.groups, resolver: preferences.resolveNames ? resolver : nil)
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        panel.nameFieldStringValue = "NetLens \(stamp).\(json ? "json" : "csv")"
        panel.allowedContentTypes = [json ? .json : .commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? (json ? ExportRecord.json(records) : ExportRecord.csv(records)).write(to: url)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section("Updates") {
                Picker("Refresh every", selection: $preferences.interval) {
                    ForEach([1.0, 2, 5, 10], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
            }
            Section("Display") {
                Toggle("Hide Apple processes", isOn: $preferences.hideApple)
                Toggle("Hide localhost traffic", isOn: $preferences.hideLocal)
                Toggle("Look up host names (sends reverse DNS queries)", isOn: $preferences.resolveNames)
                Toggle("Mask IP addresses and host names (for screenshots and screen sharing)", isOn: $preferences.maskAddresses)
            }
            Section("Hidden processes") {
                if preferences.hiddenProcesses.isEmpty {
                    Text("None. Right-click a process to hide it.").foregroundStyle(.secondary)
                }
                ForEach(preferences.hiddenProcesses, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button("Show") { preferences.hiddenProcesses.removeAll { $0 == name } }.controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
