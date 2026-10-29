import Foundation
import Darwin

// MARK: - Models

enum Proto: String, Codable, CaseIterable {
    case tcp = "TCP"
    case udp = "UDP"
}

struct Endpoint: Hashable, Codable {
    var address: String
    var port: Int

    var isUnspecified: Bool { address == "0.0.0.0" || address == "::" }
    var isLoopback: Bool { address.hasPrefix("127.") || address == "::1" }

    var display: String {
        let host = address == "0.0.0.0" ? "*" : address.contains(":") ? "[\(address)]" : address
        return "\(host):\(port == 0 ? "*" : String(port))"
    }

    /// Builds an endpoint from raw address bytes in network order. IPv4-mapped IPv6 addresses are shown as IPv4.
    init?(family: Int32, address bytes: [UInt8], port networkPort: UInt16) {
        var bytes = bytes
        var family = family
        if family == AF_INET6, bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            bytes = Array(bytes[12..<16])
            family = AF_INET
        }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard (family == AF_INET && bytes.count >= 4) || (family == AF_INET6 && bytes.count >= 16),
              inet_ntop(family, bytes, &text, socklen_t(text.count)) != nil else { return nil }
        address = String(cString: text)
        port = Int(UInt16(bigEndian: networkPort))
    }

    /// Parses a `sockaddr_in` or `sockaddr_in6` held in `Data`.
    init?(sockaddr data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return nil }
        let port = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
        switch Int32(bytes[1]) {
        case AF_INET: self.init(family: AF_INET, address: Array(bytes[4..<8]), port: port)
        case AF_INET6 where bytes.count >= 24: self.init(family: AF_INET6, address: Array(bytes[8..<24]), port: port)
        default: return nil
        }
    }
}

/// One socket as reported by a backend, before rates and process details are added.
struct RawSocket {
    var pid: pid_t
    var processName: String
    var proto: Proto
    var local: Endpoint
    var remote: Endpoint?
    var state: String?
    var interface: String?
    var rxBytes: UInt64?
    var txBytes: UInt64?
}

private func interfaceName(_ index: UInt32) -> String? {
    guard index > 0 else { return nil }
    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
    return if_indextoname(index, &name).map { _ in String(cString: name) }
}

// MARK: - NetworkStatistics backend

/// Reads sockets through the NetworkStatistics framework, the same source `nettop` uses.
/// It reports per-socket traffic counters and needs no special rights for the user's own processes.
/// The framework is private, so it's loaded at runtime and the app falls back to `libproc` if it's missing.
final class NetworkStatisticsBackend {
    private typealias SourceBlock = @convention(block) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias DescriptionBlock = @convention(block) (NSDictionary) -> Void
    private typealias DoneBlock = @convention(block) () -> Void
    private typealias Create = @convention(c) (CFAllocator?, DispatchQueue, @escaping SourceBlock) -> Unmanaged<AnyObject>?
    private typealias SetDescriptionBlock = @convention(c) (UnsafeMutableRawPointer?, @escaping DescriptionBlock) -> Void
    private typealias ManagerCall = @convention(c) (AnyObject) -> Void
    private typealias Query = @convention(c) (AnyObject, @escaping DoneBlock) -> Void
    private typealias SetFlags = @convention(c) (AnyObject, Int32) -> Int32

    private let create: Create
    private let setDescriptionBlock: SetDescriptionBlock
    private let setCountsBlock: SetDescriptionBlock
    private let addAllTCP: ManagerCall
    private let addAllUDP: ManagerCall
    private let queryDescriptions: Query
    private let queryCounts: Query
    private let setFlags: SetFlags
    private let destroy: ManagerCall

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_NOW)
        else { return nil }
        func load<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let create = load("NStatManagerCreate", as: Create.self),
              let setDescriptionBlock = load("NStatSourceSetDescriptionBlock", as: SetDescriptionBlock.self),
              let setCountsBlock = load("NStatSourceSetCountsBlock", as: SetDescriptionBlock.self),
              let addAllTCP = load("NStatManagerAddAllTCP", as: ManagerCall.self),
              let addAllUDP = load("NStatManagerAddAllUDP", as: ManagerCall.self),
              let queryDescriptions = load("NStatManagerQueryAllSourcesDescriptions", as: Query.self),
              let queryCounts = load("NStatManagerQueryAllSources", as: Query.self),
              let setFlags = load("NStatManagerSetFlags", as: SetFlags.self),
              let destroy = load("NStatManagerDestroy", as: ManagerCall.self)
        else { return nil }
        self.create = create
        self.setDescriptionBlock = setDescriptionBlock
        self.setCountsBlock = setCountsBlock
        self.addAllTCP = addAllTCP
        self.addAllUDP = addAllUDP
        self.queryDescriptions = queryDescriptions
        self.queryCounts = queryCounts
        self.setFlags = setFlags
        self.destroy = destroy
    }

    /// Descriptions carry the addresses and state, counts carry the traffic; both are keyed by source.
    func snapshot() -> [RawSocket]? {
        let queue = DispatchQueue(label: "NetLens.nstat")
        var descriptions: [Int: NSDictionary] = [:]
        var counts: [Int: NSDictionary] = [:]
        let setDescriptionBlock = self.setDescriptionBlock
        let setCountsBlock = self.setCountsBlock
        guard let manager = create(kCFAllocatorDefault, queue, { source, _ in
            let key = Int(bitPattern: source)
            setDescriptionBlock(source) { descriptions[key] = $0 }
            setCountsBlock(source) { counts[key] = $0 }
        })?.takeUnretainedValue() else { return nil }
        defer { destroy(manager) }

        _ = setFlags(manager, 0)
        addAllTCP(manager)
        addAllUDP(manager)
        // Each completion hops through the queue once more so every block queued before it has run.
        for query in [queryDescriptions, queryCounts] {
            let done = DispatchSemaphore(value: 0)
            query(manager) { queue.async { done.signal() } }
            guard done.wait(timeout: .now() + 3) == .success else { return nil }
        }
        return queue.sync { descriptions.compactMap { key, description in Self.parse(description, counts: counts[key]) } }
    }

    private static func parse(_ description: NSDictionary, counts: NSDictionary?) -> RawSocket? {
        guard let proto = (description["provider"] as? String).flatMap(Proto.init(rawValue:)),
              let pid = (description["processID"] as? NSNumber)?.int32Value,
              let local = (description["localAddress"] as? Data).flatMap(Endpoint.init(sockaddr:)) else { return nil }
        var remote = (description["remoteAddress"] as? Data).flatMap(Endpoint.init(sockaddr:))
        if let endpoint = remote, endpoint.isUnspecified, endpoint.port == 0 { remote = nil }
        return RawSocket(pid: pid, processName: description["processName"] as? String ?? "pid \(pid)",
                         proto: proto, local: local, remote: remote,
                         state: (description["TCPState"] as? String).map(readableState),
                         interface: (description["interface"] as? NSNumber).flatMap { interfaceName($0.uint32Value) },
                         rxBytes: (counts?["rxBytes"] as? NSNumber)?.uint64Value,
                         txBytes: (counts?["txBytes"] as? NSNumber)?.uint64Value)
    }

    /// "SynSent" becomes "SYN Sent", "CloseWait" becomes "Close Wait".
    private static func readableState(_ state: String) -> String {
        var words: [String] = []
        for character in state {
            if character.isUppercase || words.isEmpty { words.append(String(character)) } else { words[words.count - 1].append(character) }
        }
        return words.map { ["Syn", "Ack", "Fin"].contains($0) ? $0.uppercased() : $0 }.joined(separator: " ")
    }
}

// MARK: - libproc backend

/// Public-API fallback: walks every process's file descriptors like `lsof` does. It has no traffic counters.
enum LibprocBackend {
    private static let tcpStates = ["Closed", "Listen", "SYN Sent", "SYN Received", "Established", "Close Wait",
                                    "FIN Wait 1", "Closing", "Last ACK", "FIN Wait 2", "Time Wait"]

    static func snapshot() -> [RawSocket] {
        let capacity = proc_listallpids(nil, 0) + 64
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = proc_listallpids(&pids, capacity * Int32(MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(count, 0))).filter { $0 > 0 }.flatMap(sockets)
    }

    private static func sockets(of pid: pid_t) -> [RawSocket] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, size)
        guard filled > 0 else { return [] }

        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        let processName = String(cString: name)

        return descriptors.prefix(Int(filled) / stride)
            .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }
            .compactMap { descriptor -> RawSocket? in
                var info = socket_fdinfo()
                let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize else { return nil }
                let socket = info.psi
                guard socket.soi_family == AF_INET || socket.soi_family == AF_INET6 else { return nil }

                let inet: in_sockinfo
                let proto: Proto
                var state: String?
                if socket.soi_kind == Int32(SOCKINFO_TCP) {
                    inet = socket.soi_proto.pri_tcp.tcpsi_ini
                    proto = .tcp
                    let index = Int(socket.soi_proto.pri_tcp.tcpsi_state)
                    state = tcpStates.indices.contains(index) ? tcpStates[index] : nil
                } else if socket.soi_kind == Int32(SOCKINFO_IN), socket.soi_protocol == IPPROTO_UDP {
                    inet = socket.soi_proto.pri_in
                    proto = .udp
                } else {
                    return nil
                }

                guard let local = endpoint(inet, local: true) else { return nil }
                var remote = endpoint(inet, local: false)
                if let endpoint = remote, endpoint.isUnspecified, endpoint.port == 0 { remote = nil }
                return RawSocket(pid: pid, processName: processName, proto: proto, local: local, remote: remote,
                                 state: state, interface: nil, rxBytes: nil, txBytes: nil)
            }
    }

    private static func endpoint(_ inet: in_sockinfo, local: Bool) -> Endpoint? {
        let port = UInt16(truncatingIfNeeded: local ? inet.insi_lport : inet.insi_fport)
        if inet.insi_vflag & UInt8(INI_IPV6) == 0 {
            let v4 = local ? inet.insi_laddr.ina_46.i46a_addr4 : inet.insi_faddr.ina_46.i46a_addr4
            return Endpoint(family: AF_INET, address: withUnsafeBytes(of: v4) { Array($0) }, port: port)
        }
        let v6 = local ? inet.insi_laddr.ina_6 : inet.insi_faddr.ina_6
        var bytes = withUnsafeBytes(of: v6) { Array($0) }
        // The kernel stores a link-local address's scope ID in bytes 2–3; clear it to get the real address.
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 {
            bytes[2] = 0
            bytes[3] = 0
        }
        return Endpoint(family: AF_INET6, address: bytes, port: port)
    }
}
