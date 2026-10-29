import AppKit
import Combine
import Security

// MARK: - Models

struct Connection: Identifiable, Hashable {
    let id: String
    let pid: pid_t
    let proto: Proto
    let local: Endpoint
    let remote: Endpoint?
    let state: String?
    let interface: String?
    let rxBytes: UInt64?
    let txBytes: UInt64?
    var rxRate: Double?
    var txRate: Double?

    var isListening: Bool { proto == .tcp ? state == "Listen" : remote == nil && local.port != 0 }
    var isLocalOnly: Bool { local.isLoopback || (remote?.isLoopback ?? false) }

    var stateLabel: String {
        if proto == .udp { return remote != nil ? "Connected" : local.port == 0 ? "Unbound" : "Listening" }
        return state ?? "–"
    }
}

enum Signer: String, Codable {
    case apple = "Apple"
    case appStore = "App Store"
    case developerID = "Developer ID"
    case signed = "Signed"
    case adHoc = "Ad hoc"
    case unsigned = "Unsigned"
    case invalid = "Invalid"
    case unknown = "Unknown"

    var isRisky: Bool { self == .unsigned || self == .invalid }
}

struct ProcessGroup: Identifiable, Hashable {
    let pid: pid_t
    let name: String
    let path: String?
    let iconPath: String?
    let signer: Signer
    var connections: [Connection]

    var id: pid_t { pid }
    var rxRate: Double? { sum(\.rxRate) }
    var txRate: Double? { sum(\.txRate) }
    var rxBytes: Double? { sum { $0.rxBytes.map { Double($0) } } }
    var txBytes: Double? { sum { $0.txBytes.map { Double($0) } } }
    var listeningCount: Int { connections.filter(\.isListening).count }

    private func sum(_ value: (Connection) -> Double?) -> Double? {
        let values = connections.compactMap(value)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    var icon: NSImage {
        NSRunningApplication(processIdentifier: pid)?.icon
            ?? iconPath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
    }
}

// MARK: - Process details

enum ProcessDetails {
    private static var signatures: [String: Signer] = [:]
    private static let lock = NSLock()

    static func path(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The outermost `.app` around a program, so helpers show their parent app's icon.
    static func outerBundle(of path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components[...index]))
    }

    static func signer(of path: String) -> Signer {
        lock.lock()
        defer { lock.unlock() }
        if let cached = signatures[path] { return cached }
        let result = check(path)
        signatures[path] = result
        return result
    }

    private static func check(_ path: String) -> Signer {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return .unknown }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSDoNotValidateResources)
        switch SecStaticCodeCheckValidity(code, flags, nil) {
        case errSecSuccess: break
        case errSecCSUnsigned: return .unsigned
        default: return .invalid
        }
        let requirements: [(Signer, String)] = [
            (.apple, "anchor apple"),
            (.appStore, "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"),
            (.developerID, "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
                + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"),
        ]
        for (signer, text) in requirements {
            var requirement: SecRequirement?
            if SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
               SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess { return signer }
        }
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [Any] ?? []
        return certificates.isEmpty ? .adHoc : .signed
    }
}

// MARK: - Monitor

/// Takes socket snapshots on a background queue, works out per-connection speeds and groups them by process.
final class Monitor: ObservableObject {
    @Published private(set) var groups: [ProcessGroup] = []
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var source = ""

    var interval: TimeInterval = 2 { didSet { if interval != oldValue { schedule() } } }
    var isPaused = false { didSet { schedule() } }

    private let queue = DispatchQueue(label: "NetLens.monitor", qos: .userInitiated)
    private let networkStatistics: NetworkStatisticsBackend?
    private var previous: [String: (rx: UInt64, tx: UInt64, time: TimeInterval)] = [:]
    private var timer: Timer?
    private var started = false

    init(useLibproc: Bool = false) {
        networkStatistics = useLibproc ? nil : NetworkStatisticsBackend()
    }

    func start() {
        started = true
        refresh()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard started, !isPaused else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = interval * 0.1
    }

    func refresh() {
        queue.async { [self] in
            let result = collect()
            DispatchQueue.main.async { [self] in
                groups = result.groups
                source = result.source
                lastUpdate = Date()
            }
        }
    }

    /// Takes one snapshot on the calling thread; used by the command-line modes.
    func refreshNow() {
        let result = queue.sync { collect() }
        groups = result.groups
        source = result.source
        lastUpdate = Date()
    }

    private func collect() -> (groups: [ProcessGroup], source: String) {
        let sockets: [RawSocket]
        let source: String
        if let snapshot = networkStatistics?.snapshot() {
            sockets = snapshot
            source = "NetworkStatistics"
        } else {
            sockets = LibprocBackend.snapshot()
            source = "libproc"
        }

        let now = ProcessInfo.processInfo.systemUptime
        var seen: [String: Int] = [:]
        var counters: [String: (rx: UInt64, tx: UInt64, time: TimeInterval)] = [:]
        var connections: [Connection] = []

        for socket in sockets {
            var id = "\(socket.proto.rawValue)|\(socket.pid)|\(socket.local.display)|\(socket.remote?.display ?? "-")"
            seen[id, default: 0] += 1
            if seen[id]! > 1 { id += "#\(seen[id]!)" }

            var rxRate: Double?, txRate: Double?
            if let rx = socket.rxBytes, let tx = socket.txBytes {
                if let before = previous[id], now > before.time {
                    rxRate = rx >= before.rx ? Double(rx - before.rx) / (now - before.time) : 0
                    txRate = tx >= before.tx ? Double(tx - before.tx) / (now - before.time) : 0
                }
                counters[id] = (rx, tx, now)
            }
            connections.append(Connection(id: id, pid: socket.pid, proto: socket.proto, local: socket.local,
                                          remote: socket.remote, state: socket.state, interface: socket.interface,
                                          rxBytes: socket.rxBytes, txBytes: socket.txBytes,
                                          rxRate: rxRate, txRate: txRate))
        }
        previous = counters

        let names = Dictionary(sockets.map { ($0.pid, $0.processName) }, uniquingKeysWith: { first, _ in first })
        let groups = Dictionary(grouping: connections, by: \.pid).map { pid, connections -> ProcessGroup in
            let path = ProcessDetails.path(pid)
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? path.map { ($0 as NSString).lastPathComponent } ?? names[pid] ?? "pid \(pid)"
            return ProcessGroup(pid: pid, name: name, path: path,
                                iconPath: path.flatMap(ProcessDetails.outerBundle) ?? path,
                                signer: path.map(ProcessDetails.signer) ?? .unknown,
                                connections: connections.sorted(by: Self.connectionOrder))
        }
        return (groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, source)
    }

    /// Established connections first, then listeners, then the rest; by remote address within each.
    private static func connectionOrder(_ a: Connection, _ b: Connection) -> Bool {
        func rank(_ connection: Connection) -> Int {
            connection.isListening ? 1 : connection.remote != nil ? 0 : 2
        }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        return (a.remote?.display ?? a.local.display) < (b.remote?.display ?? b.local.display)
    }
}

// MARK: - Reverse DNS

/// Looks up host names for remote addresses in the background and caches the answers.
final class Resolver: ObservableObject {
    @Published private(set) var names: [String: String] = [:]
    private var pending: Set<String> = []
    private let queue = DispatchQueue(label: "NetLens.resolver", attributes: .concurrent)

    func name(for address: String) -> String? {
        guard let name = names[address], !name.isEmpty else { return nil }
        return name
    }

    func lookUp(_ address: String) {
        guard names[address] == nil, !pending.contains(address) else { return }
        pending.insert(address)
        queue.async { [weak self] in
            let name = Self.reverseLookup(address)
            DispatchQueue.main.async {
                self?.pending.remove(address)
                self?.names[address] = name ?? ""
            }
        }
    }

    private static func reverseLookup(_ address: String) -> String? {
        var storage = sockaddr_storage()
        let length: Int
        if address.contains(":") {
            var v6 = sockaddr_in6()
            v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            v6.sin6_family = sa_family_t(AF_INET6)
            guard inet_pton(AF_INET6, address, &v6.sin6_addr) == 1 else { return nil }
            withUnsafeBytes(of: v6) { raw in withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: raw) } }
            length = MemoryLayout<sockaddr_in6>.size
        } else {
            var v4 = sockaddr_in()
            v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            v4.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, address, &v4.sin_addr) == 1 else { return nil }
            withUnsafeBytes(of: v4) { raw in withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: raw) } }
            length = MemoryLayout<sockaddr_in>.size
        }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(length), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        return status == 0 ? String(cString: host) : nil
    }
}

// MARK: - Preferences

final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var hideApple: Bool { didSet { defaults.set(hideApple, forKey: "hideApple") } }
    @Published var hideLocal: Bool { didSet { defaults.set(hideLocal, forKey: "hideLocal") } }
    @Published var resolveNames: Bool { didSet { defaults.set(resolveNames, forKey: "resolveNames") } }
    @Published var maskAddresses: Bool { didSet { defaults.set(maskAddresses, forKey: "maskAddresses") } }
    @Published var interval: Double { didSet { defaults.set(interval, forKey: "interval") } }
    /// Process names the user chose to hide.
    @Published var hiddenProcesses: [String] { didSet { defaults.set(hiddenProcesses, forKey: "hiddenProcesses") } }

    init() {
        hideApple = defaults.bool(forKey: "hideApple")
        hideLocal = defaults.bool(forKey: "hideLocal")
        resolveNames = defaults.bool(forKey: "resolveNames")
        maskAddresses = defaults.bool(forKey: "maskAddresses")
        let interval = defaults.double(forKey: "interval")
        self.interval = interval > 0 ? interval : 2
        hiddenProcesses = defaults.stringArray(forKey: "hiddenProcesses") ?? []
    }

    /// Hides every real address, for screenshots and screen sharing. Local and remote IPs (and host names)
    /// can reveal who and roughly where you are; only loopback and wildcard addresses stay visible.
    func display(_ endpoint: Endpoint) -> String {
        guard maskAddresses, !endpoint.isLoopback, !endpoint.isUnspecified else { return endpoint.display }
        let port = endpoint.port == 0 ? "*" : String(endpoint.port)
        if endpoint.address.contains(":") {
            return (endpoint.address.lowercased().hasPrefix("fe80:") ? "[fe80:•••]" : "[•••]") + ":" + port
        }
        return "•.•.•.•:" + port
    }

    /// The remote host as shown in the first column: its host name if known, otherwise the address.
    func host(_ endpoint: Endpoint, resolver: Resolver) -> String {
        if maskAddresses, !endpoint.isLoopback {
            return endpoint.address.contains(":") ? "IPv6 host" : "IPv4 host"
        }
        return resolver.name(for: endpoint.address) ?? endpoint.address
    }
}

// MARK: - Formatting

enum Format {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func bytes(_ value: Double?) -> String {
        guard let value else { return "–" }
        return formatter.string(fromByteCount: Int64(value))
    }

    static func rate(_ value: Double?) -> String {
        guard let value else { return "–" }
        if value < 1 { return "0" }
        return formatter.string(fromByteCount: Int64(value)) + "/s"
    }
}
