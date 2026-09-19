import AppKit
import CryptoKit
import Darwin
import Foundation

private let latteProtocolVersion = 1
private let latteMaximumResponseBytes = 1_048_576
private let latteRequestTimeoutNanoseconds: UInt64 = 2_000_000_000
private let latteSocketWaitNanoseconds: UInt64 = 250_000_000

private enum LatteError: LocalizedError {
    case daemonUnavailable(String)
    case invalidConfiguration(String)
    case invalidResponse(String)
    case transport(String)
    case server(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case let .daemonUnavailable(message):
            return "Daemon unavailable: \(message)"
        case let .invalidConfiguration(message):
            return "Invalid Latte configuration: \(message)"
        case let .invalidResponse(message):
            return "Invalid daemon response: \(message)"
        case let .transport(message):
            return "Could not contact Latte: \(message)"
        case let .server(code, _):
            return "Latte daemon error (\(code)): the request failed"
        }
    }
}

private struct ServiceStatus: Decodable {
    enum State: String, Decodable {
        case running
        case stopped
        case failed
        case starting
        case stopping
    }

    let state: State
    let detail: String?
}

private struct StatusResponse: Decodable {
    let version: Int
    let services: [String: ServiceStatus]
    let error: String?

    var diagnostic: String? {
        guard let error else { return nil }
        let compact = error.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !compact.isEmpty else { return nil }
        return String(compact.prefix(240))
    }
}

private struct Site: Decodable {
    let id: String
    let name: String
    let directory: String
    let suffix: String
    let domain: String
    let origin: String
    let upstream: String?
    let state: String?
    let owner: String?

    var stateLabel: String {
        switch state {
        case "running": return "Running"
        case "building": return "Building"
        case "build-error": return "Build error"
        case "stopped": return "Stopped"
        case "unavailable": return "Unavailable"
        default: return "Unknown"
        }
    }

    var ownerLabel: String? {
        owner == "terminal" ? "Terminal session" : nil
    }

    func validatedURL() throws -> URL {
        let domainParts = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard !id.isEmpty,
              id.utf8.count <= 256,
              !id.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              domainParts.count == 2,
              domainParts[0] == Substring(name),
              domainParts[1] == Substring(suffix),
              suffix == "caramel" || suffix == "test",
              Site.isValidProjectLabel(String(domainParts[0])) else {
            throw LatteError.invalidResponse("site domain is not a validated local hostname")
        }

        let expectedOrigin = "https://\(domain)"
        guard origin == expectedOrigin else {
            throw LatteError.invalidResponse("site origin does not match its validated domain")
        }
        guard let url = URL(string: origin),
              url.scheme == "https",
              url.host == domain,
              url.port == nil,
              (url.path.isEmpty || url.path == "/"),
              url.query == nil,
              url.fragment == nil,
              url.user == nil else {
            throw LatteError.invalidResponse("site origin is not a plain HTTPS URL")
        }
        return url
    }

    func validatedDirectoryURL() throws -> URL {
        guard !directory.isEmpty,
              !directory.contains("\0"),
              directory.hasPrefix("/") else {
            throw LatteError.invalidResponse("site directory is not an absolute local path")
        }
        return URL(fileURLWithPath: directory, isDirectory: true)
    }

    private static func isValidProjectLabel(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 63,
              bytes[0] >= 97, bytes[0] <= 122,
              bytes[bytes.count - 1] != 45 else {
            return false
        }
        return bytes.dropFirst().allSatisfy { byte in
            (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45
        }
    }
}

private struct SitesResponse: Decodable {
    let version: Int
    let sites: [Site]
}

private struct LatteSnapshot {
    let status: StatusResponse
    let sites: [Site]
}

private struct LatteRuntime {
    let home: URL
    let runtimeDirectory: URL
    let socket: URL
    let logs: URL
    let uid: uid_t

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let configuredHome = environment["CARAMEL_HOME"]
            ?? (FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Caramel", isDirectory: true)
                .path)
        let expandedHome = (configuredHome as NSString).expandingTildeInPath
        guard !expandedHome.isEmpty else {
            throw LatteError.invalidConfiguration("CARAMEL_HOME is empty")
        }
        guard !Self.containsSymlink(expandedHome) else {
            throw LatteError.invalidConfiguration("CARAMEL_HOME contains a symlink")
        }

        let canonicalPath = Self.canonicalPath(expandedHome)
        let canonicalHome = URL(fileURLWithPath: canonicalPath, isDirectory: true)
        let hash = SHA256.hash(data: Data(canonicalHome.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(12)
        let currentUID = getuid()
        let runtime = URL(fileURLWithPath: "/private/tmp/caramel-\(currentUID)-\(hash)", isDirectory: true)

        self.home = canonicalHome
        self.runtimeDirectory = runtime
        self.socket = runtime.appendingPathComponent("latte.sock", isDirectory: false)
        self.logs = canonicalHome.appendingPathComponent("logs", isDirectory: true)
        self.uid = currentUID
    }

    private static func canonicalPath(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missingComponents.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }

        var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = existing.path.withCString { realpath($0, &resolvedPath) != nil }
        var result = resolved ? String(cString: resolvedPath) : existing.path
        for component in missingComponents {
            result = URL(fileURLWithPath: result, isDirectory: true)
                .appendingPathComponent(component, isDirectory: true)
                .path
        }
        return result
    }

    private static func containsSymlink(_ path: String) -> Bool {
        var current = lexicallyNormalizedPath(path)
        let components = current.split(separator: "/", omittingEmptySubsequences: true)
        current = current.hasPrefix("/") ? "/" : ""
        for component in components {
            current = current == "/" ? "/\(component)" : (current.isEmpty ? String(component) : "\(current)/\(component)")
            var info = stat()
            guard lstat(current, &info) == 0 else { continue }
            if (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                return true
            }
        }
        return false
    }

    private static func lexicallyNormalizedPath(_ path: String) -> String {
        let absolute = path.hasPrefix("/") ? path : "\(FileManager.default.currentDirectoryPath)/\(path)"
        var components: [Substring] = []
        for component in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." {
                continue
            }
            if component == ".." {
                if !components.isEmpty {
                    components.removeLast()
                }
                continue
            }
            components.append(component)
        }
        return "/" + components.joined(separator: "/")
    }

    func verifyOwnedSocket() throws {
        try verifyDirectory(home, mode: 0o700, name: "Caramel home")
        try verifyDirectory(runtimeDirectory, mode: 0o700, name: "Latte runtime directory")

        var info = stat()
        guard lstat(socket.path, &info) == 0 else {
            if errno == ENOENT {
                throw LatteError.daemonUnavailable("the owner-local socket is not running")
            }
            throw LatteError.daemonUnavailable("cannot inspect the owner-local socket: \(posixError())")
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            throw LatteError.daemonUnavailable("the Latte socket path is not a UNIX socket")
        }
        guard info.st_uid == uid else {
            throw LatteError.daemonUnavailable("the Latte socket has a different owner")
        }
        guard (info.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw LatteError.daemonUnavailable("the Latte socket is not private (expected 0600)")
        }
    }

    private func verifyDirectory(_ url: URL, mode: mode_t, name: String) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT {
                throw LatteError.daemonUnavailable("\(name) is missing")
            }
            throw LatteError.daemonUnavailable("cannot inspect \(name): \(posixError())")
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw LatteError.daemonUnavailable("\(name) is not a directory")
        }
        guard info.st_uid == uid else {
            throw LatteError.daemonUnavailable("\(name) has a different owner")
        }
        guard (info.st_mode & mode_t(0o777)) == mode else {
            throw LatteError.daemonUnavailable("\(name) is not private (expected \(String(mode, radix: 8)))")
        }
    }

    private func posixError() -> String {
        String(cString: strerror(errno))
    }
}

private final class LatteHTTPClient {
    let runtime: LatteRuntime
    private let decoder = JSONDecoder()

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        self.runtime = try LatteRuntime(environment: environment)
    }

    func snapshot() throws -> LatteSnapshot {
        try snapshot(deadline: operationDeadline())
    }

    fileprivate func snapshot(deadline: UInt64) throws -> LatteSnapshot {
        let status: StatusResponse = try requestJSON(method: "GET", path: "/v1/status", body: nil, deadline: deadline)
        guard status.version == latteProtocolVersion else {
            throw LatteError.invalidResponse("unsupported status protocol version \(status.version)")
        }
        for required in ["postgres", "dns", "proxy"] {
            guard status.services[required] != nil else {
                throw LatteError.invalidResponse("status omitted \(required) service")
            }
        }

        let sitesResponse: SitesResponse = try requestJSON(method: "GET", path: "/v1/sites", body: nil, deadline: deadline)
        if sitesResponse.version != latteProtocolVersion {
            throw LatteError.invalidResponse("unsupported sites protocol version \(sitesResponse.version)")
        }
        var seenIDs = Set<String>()
        var seenDomains = Set<String>()
        for site in sitesResponse.sites {
            _ = try site.validatedURL()
            _ = try site.validatedDirectoryURL()
            guard seenIDs.insert(site.id).inserted else {
                throw LatteError.invalidResponse("sites response contained a duplicate site ID")
            }
            guard seenDomains.insert(site.domain).inserted else {
                throw LatteError.invalidResponse("sites response contained a duplicate domain")
            }
        }
        return LatteSnapshot(status: status, sites: sitesResponse.sites)
    }

    func serviceCommand(_ action: String) throws -> StatusResponse {
        try serviceCommand(action, deadline: operationDeadline())
    }

    fileprivate func serviceCommand(_ action: String, deadline: UInt64) throws -> StatusResponse {
        guard action == "start" || action == "stop" else {
            throw LatteError.invalidConfiguration("unsupported service action")
        }
        let payload = Data("{}".utf8)
        let status: StatusResponse = try requestJSON(method: "POST", path: "/v1/services/\(action)", body: payload, deadline: deadline)
        guard status.version == latteProtocolVersion else {
            throw LatteError.invalidResponse("unsupported status protocol version \(status.version)")
        }
        for required in ["postgres", "dns", "proxy"] {
            guard status.services[required] != nil else {
                throw LatteError.invalidResponse("service command omitted \(required) service")
            }
        }
        return status
    }

    fileprivate func operationDeadline() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds &+ latteRequestTimeoutNanoseconds
    }

    private func requestJSON<T: Decodable>(method: String, path: String, body: Data?, deadline: UInt64) throws -> T {
        let responseBody = try request(method: method, path: path, body: body, deadline: deadline)
        do {
            return try decoder.decode(T.self, from: responseBody)
        } catch {
            throw LatteError.invalidResponse("JSON could not be decoded")
        }
    }

    private func request(method: String, path: String, body: Data?, deadline: UInt64) throws -> Data {
        try ensureBeforeDeadline(deadline, operation: "starting the daemon request")
        try runtime.verifyOwnedSocket()
        guard path.hasPrefix("/v1/"), !path.contains(".."), !path.contains("\0") else {
            throw LatteError.invalidConfiguration("invalid control path")
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw LatteError.transport("could not create a UNIX socket")
        }
        defer { close(descriptor) }

        var noSigPipe: Int32 = 1
        guard withUnsafePointer(to: &noSigPipe, {
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }) == 0 else {
            throw LatteError.transport("could not protect the control socket")
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        guard withUnsafePointer(to: &timeout, {
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }) == 0 else {
            throw LatteError.transport("could not configure the control socket receive timeout")
        }
        guard withUnsafePointer(to: &timeout, {
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }) == 0 else {
            throw LatteError.transport("could not configure the control socket send timeout")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let socketBytes = Array(runtime.socket.path.utf8)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketBytes.count + 1 < pathCapacity else {
            throw LatteError.invalidConfiguration("control socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in socketBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }

        try connect(descriptor, to: &address, deadline: deadline)

        var request = "\(method) \(path) HTTP/1.1\r\nHost: latte.local\r\nAccept: application/json\r\nConnection: close\r\n"
        if let body {
            request += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        } else {
            request += "Content-Length: 0\r\n"
        }
        request += "\r\n"
        var requestData = Data(request.utf8)
        if let body {
            requestData.append(body)
        }
        try writeAll(descriptor, data: requestData, deadline: deadline)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            try ensureBeforeDeadline(deadline, operation: "waiting for the daemon")
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.recv(descriptor, rawBuffer.baseAddress, rawBuffer.count, 0)
            }
            if count == 0 {
                try ensureBeforeDeadline(deadline, operation: "waiting for the daemon")
                break
            }
            if count < 0 {
                if errno == EINTR {
                    try ensureBeforeDeadline(deadline, operation: "waiting for the daemon")
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try ensureBeforeDeadline(deadline, operation: "waiting for the daemon")
                    continue
                }
                throw LatteError.transport("timed out waiting for the daemon")
            }
            response.append(contentsOf: buffer[0..<count])
            if response.count > latteMaximumResponseBytes {
                throw LatteError.invalidResponse("response exceeded the size limit")
            }
            try ensureBeforeDeadline(deadline, operation: "reading the daemon response")
        }

        return try parseHTTPResponse(response)
    }

    private func writeAll(_ descriptor: Int32, data: Data, deadline: UInt64) throws {
        var offset = 0
        while offset < data.count {
            try ensureBeforeDeadline(deadline, operation: "sending the daemon request")
            let count = data.withUnsafeBytes { rawBuffer in
                Darwin.send(descriptor, rawBuffer.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            if count < 0 {
                if errno == EINTR {
                    try ensureBeforeDeadline(deadline, operation: "sending the daemon request")
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try ensureBeforeDeadline(deadline, operation: "sending the daemon request")
                    continue
                }
                throw LatteError.transport("could not send the daemon request")
            }
            guard count > 0 else {
                throw LatteError.transport("daemon closed the control socket")
            }
            offset += count
            try ensureBeforeDeadline(deadline, operation: "sending the daemon request")
        }
    }

    private func connect(_ descriptor: Int32, to address: inout sockaddr_un, deadline: UInt64) throws {
        let originalFlags = fcntl(descriptor, F_GETFL, 0)
        guard originalFlags >= 0,
              fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw LatteError.transport("could not configure the control socket")
        }
        defer { _ = fcntl(descriptor, F_SETFL, originalFlags) }

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected == 0 {
            return
        }
        guard errno == EINPROGRESS || errno == EALREADY else {
            throw LatteError.daemonUnavailable("the owner-local socket could not be reached")
        }

        while true {
            try ensureBeforeDeadline(deadline, operation: "connecting to the daemon")
            var readiness = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let pollResult = Darwin.poll(&readiness, 1, remainingPollMilliseconds(deadline))
            if pollResult < 0 {
                if errno == EINTR {
                    try ensureBeforeDeadline(deadline, operation: "connecting to the daemon")
                    continue
                }
                throw LatteError.daemonUnavailable("the owner-local socket could not be reached")
            }
            if pollResult == 0 {
                continue
            }

            var socketError: Int32 = 0
            var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) == 0 else {
                throw LatteError.daemonUnavailable("the owner-local socket could not be reached")
            }
            if socketError == 0 && (readiness.revents & Int16(POLLOUT)) != 0 {
                return
            }
            throw LatteError.daemonUnavailable("the owner-local socket could not be reached")
        }
    }

    private func ensureBeforeDeadline(_ deadline: UInt64, operation: String) throws {
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw LatteError.transport("timed out \(operation)")
        }
    }

    private func remainingPollMilliseconds(_ deadline: UInt64) -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return 0 }
        let remaining = deadline - now
        let milliseconds = max(1, Int(remaining / 1_000_000))
        return Int32(min(milliseconds, Int(latteSocketWaitNanoseconds / 1_000_000)))
    }

    private func parseHTTPResponse(_ response: Data) throws -> Data {
        let separator = Data([13, 10, 13, 10])
        guard let headerRange = response.range(of: separator) else {
            throw LatteError.invalidResponse("HTTP headers were incomplete")
        }
        let headerData = response.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw LatteError.invalidResponse("HTTP headers were not UTF-8")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw LatteError.invalidResponse("HTTP status was missing")
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw LatteError.invalidResponse("HTTP status was malformed")
        }

        var contentLength: Int?
        var contentType: String?
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            guard pieces.count == 2 else { continue }
            if pieces[0].lowercased() == "content-length" {
                guard let length = Int(pieces[1].trimmingCharacters(in: .whitespaces)) else {
                    throw LatteError.invalidResponse("HTTP body length was malformed")
                }
                contentLength = length
            } else if pieces[0].lowercased() == "content-type" {
                contentType = pieces[1].trimmingCharacters(in: .whitespaces).lowercased()
            }
        }

        guard contentType?.hasPrefix("application/json") == true else {
            throw LatteError.invalidResponse("daemon response was not JSON")
        }

        var body = response.subdata(in: headerRange.upperBound..<response.endIndex)
        if let contentLength {
            guard contentLength >= 0, contentLength <= latteMaximumResponseBytes else {
                throw LatteError.invalidResponse("HTTP body exceeded the size limit")
            }
            guard body.count >= contentLength else {
                throw LatteError.invalidResponse("HTTP body was incomplete")
            }
            body = body.prefix(contentLength)
        }

        guard (200..<300).contains(statusCode) else {
            if let error = try? decoder.decode(ServerErrorResponse.self, from: body) {
                let code = error.error.code.isEmpty ? "request_failed" : error.error.code
                let message = String(error.error.message.prefix(240))
                throw LatteError.server(code: code, message: message)
            }
            throw LatteError.server(code: "http_\(statusCode)", message: "the daemon rejected the request")
        }
        return body
    }
}

private struct ServerErrorResponse: Decodable {
    struct ErrorBody: Decodable {
        let code: String
        let message: String
    }

    let error: ErrorBody
}

private enum LatteDiagnostics {
    static func run() -> Int32 {
        do {
            let client = try LatteHTTPClient()
            print("socket: \(client.runtime.socket.path)")
            let snapshot = try client.snapshot()
            let serviceNames = ["postgres", "dns", "proxy"]
            let status = serviceNames.compactMap { name -> String? in
                guard let service = snapshot.status.services[name] else { return nil }
                return "\(name)=\(service.state.rawValue)"
            }.joined(separator: " ")
            print("status: \(status)")
            if let diagnostic = snapshot.status.diagnostic {
                print("diagnostic: \(diagnostic)")
            }
            print("sites: \(snapshot.sites.count)")
            for site in snapshot.sites.sorted(by: { $0.name < $1.name }) {
                print("- \(site.name) \(site.origin) [\(site.stateLabel)]\(site.ownerLabel.map { " · " + $0 } ?? "")")
            }
            return 0
        } catch {
            fputs("latte check failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}

private final class LatteAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let client: LatteHTTPClient?
    private var clientError: String?
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var snapshot: LatteSnapshot?
    private var lastError: String?
    private var requestInFlight = false
    private var refreshTimer: Timer?
    private var sitesByID: [String: Site] = [:]

    override init() {
        do {
            self.client = try LatteHTTPClient()
        } catch {
            self.client = nil
            self.clientError = error.localizedDescription
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Caramel Latte") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "☕"
            }
            button.toolTip = "Caramel Latte"
        }
        let appMenu = NSMenu()
        appMenu.autoenablesItems = false
        appMenu.delegate = self
        item.menu = appMenu
        self.statusItem = item
        self.menu = appMenu
        renderMenu()
        refresh()
        refreshTimer = Timer.scheduledTimer(timeInterval: 10, target: self, selector: #selector(refreshTimerFired), userInfo: nil, repeats: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    @objc private func refreshTimerFired() {
        refresh()
    }

    @objc private func refreshAction(_ sender: Any?) {
        refresh()
    }

    private func refresh() {
        guard !requestInFlight else { return }
        guard let client else {
            lastError = clientError ?? "the client could not be initialized"
            renderMenu()
            return
        }
        requestInFlight = true
        if snapshot == nil {
            lastError = "Contacting daemon…"
            renderMenu()
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: Result<LatteSnapshot, Error>
            do {
                result = .success(try client.snapshot())
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.requestInFlight = false
                switch result {
                case let .success(value):
                    self.snapshot = value
                    self.sitesByID = Dictionary(uniqueKeysWithValues: value.sites.map { ($0.id, $0) })
                    self.lastError = nil
                case let .failure(error):
                    self.lastError = error.localizedDescription
                }
                self.renderMenu()
            }
        }
    }

    private func serviceCommand(_ action: String) {
        guard !requestInFlight, let client else { return }
        requestInFlight = true
        lastError = "\(action == "start" ? "Starting" : "Stopping") services…"
        renderMenu()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: Result<LatteSnapshot, Error>
            do {
                let deadline = client.operationDeadline()
                _ = try client.serviceCommand(action, deadline: deadline)
                result = .success(try client.snapshot(deadline: deadline))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.requestInFlight = false
                switch result {
                case let .success(value):
                    self.snapshot = value
                    self.sitesByID = Dictionary(uniqueKeysWithValues: value.sites.map { ($0.id, $0) })
                    self.lastError = nil
                case let .failure(error):
                    self.lastError = error.localizedDescription
                }
                self.renderMenu()
            }
        }
    }

    private func renderMenu() {
        guard let menu else { return }
        menu.removeAllItems()

        let title = NSMenuItem(title: "Caramel • Latte", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        if let snapshot {
            let statusNames = ["postgres", "dns", "proxy"]
            let serviceText = statusNames.compactMap { name -> String? in
                guard let service = snapshot.status.services[name] else { return nil }
                return "\(name)=\(service.state.rawValue)"
            }.joined(separator: "  ")
            let statusItem = NSMenuItem(title: "Services  \(serviceText)", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)

            if let diagnostic = snapshot.status.diagnostic {
                addDisabledItem("Daemon: \(diagnostic)", to: menu)
            }

            if let lastError, !lastError.isEmpty {
                addDisabledItem(lastError, to: menu)
            }

            if snapshot.sites.isEmpty {
                addDisabledItem("No registered sites", to: menu)
            } else {
                for site in snapshot.sites.sorted(by: { $0.name < $1.name }) {
                    let siteItem = NSMenuItem(title: site.name + "  ·  " + site.stateLabel, action: nil, keyEquivalent: "")
                    let siteMenu = NSMenu()
                    siteMenu.autoenablesItems = false
                    addDisabledItem(site.origin, to: siteMenu)
                    if let owner = site.ownerLabel { addDisabledItem(owner, to: siteMenu) }
                    siteMenu.addItem(actionItem("Open site", action: #selector(openSite(_:)), id: site.id))
                    siteMenu.addItem(actionItem("Open folder", action: #selector(openFolder(_:)), id: site.id))
                    siteMenu.addItem(actionItem("Open logs", action: #selector(openLogs(_:)), id: site.id))
                    siteItem.submenu = siteMenu
                    menu.addItem(siteItem)
                }
            }

            menu.addItem(.separator())
            let start = actionItem("Start services", action: #selector(startServices(_:)), id: nil)
            start.isEnabled = !requestInFlight
            menu.addItem(start)
            let stop = actionItem("Stop services", action: #selector(stopServices(_:)), id: nil)
            stop.isEnabled = !requestInFlight
            menu.addItem(stop)
        } else {
            addDisabledItem(lastError ?? clientError ?? "Daemon unavailable", to: menu)
            menu.addItem(.separator())
            let start = actionItem("Start services", action: #selector(startServices(_:)), id: nil)
            start.isEnabled = false
            menu.addItem(start)
            let stop = actionItem("Stop services", action: #selector(stopServices(_:)), id: nil)
            stop.isEnabled = false
            menu.addItem(stop)
        }

        menu.addItem(.separator())
        let refresh = actionItem(requestInFlight ? "Refreshing…" : "Refresh", action: #selector(refreshAction(_:)), id: nil)
        refresh.isEnabled = !requestInFlight
        menu.addItem(refresh)
        menu.addItem(NSMenuItem(title: "Quit Latte UI", action: #selector(quit(_:)), keyEquivalent: "q"))
        menu.items.last?.target = self
    }

    private func addDisabledItem(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func actionItem(_ title: String, action: Selector, id: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let id {
            item.representedObject = id
        }
        return item
    }

    @objc private func openSite(_ sender: NSMenuItem) {
        guard let site = site(for: sender), let url = try? site.validatedURL() else {
            lastError = "The daemon returned an invalid site origin"
            renderMenu()
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openFolder(_ sender: NSMenuItem) {
        guard let site = site(for: sender), let url = try? site.validatedDirectoryURL() else {
            lastError = "The daemon returned an invalid site folder"
            renderMenu()
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openLogs(_ sender: NSMenuItem) {
        guard let client else { return }
        let url = client.runtime.logs
        NSWorkspace.shared.open(url)
    }

    @objc private func startServices(_ sender: Any?) {
        serviceCommand("start")
    }

    @objc private func stopServices(_ sender: Any?) {
        serviceCommand("stop")
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func site(for item: NSMenuItem) -> Site? {
        guard let value = item.representedObject as? String else { return nil }
        return sitesByID[value]
    }
}

@main
private struct LatteMain {
    static func main() {
        if CommandLine.arguments.dropFirst().contains("--check") {
            exit(LatteDiagnostics.run())
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = LatteAppDelegate()
        application.delegate = delegate
        application.run()
    }
}
