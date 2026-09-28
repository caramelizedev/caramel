import Foundation
import Darwin

private let relayPath = "/Library/PrivilegedHelperTools/dev.caramel.ports"
private let resolverBytes = Data("# Managed by Caramel Latte\nnameserver 127.0.0.1\nport 15353\n".utf8)
private let jobLabel = "system/dev.caramel.ports"

private func integrationError(_ text: String) -> InstallerError { InstallerError(message: text) }

private func statOf(_ path: String) -> stat? {
    var info = stat()
    return path.withCString { lstat($0, &info) == 0 ? info : nil }
}

private func existing(_ path: String) -> Bool { statOf(path) != nil }

private func ownedBytes(_ path: String, uid: uid_t, privateFile: Bool = false) throws -> Data {
    guard let info = statOf(path), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          info.st_uid == uid, info.st_mode & (privateFile ? 0o077 : 0o022) == 0 else {
        throw integrationError("Unexpected file ownership or permissions: \(path)")
    }
    return try Data(contentsOf: URL(fileURLWithPath: path))
}

private func account(_ uid: uid_t) throws -> String {
    guard let user = getpwuid(uid), let name = user.pointee.pw_name else {
        throw integrationError("Installing account changed")
    }
    return String(cString: name)
}

private func plistConfiguration(username: String) -> [String: Any] {
    func socket(_ port: String) -> [String: String] {
        ["SockNodeName": "127.0.0.1", "SockFamily": "IPv4", "SockServiceName": port, "SockType": "stream"]
    }
    return ["Label": "dev.caramel.ports", "UserName": username,
            "ProgramArguments": [relayPath], "Program": relayPath,
            "Sockets": ["http": socket("80"), "https": socket("443")],
            "RunAtLoad": true, "KeepAlive": true, "ProcessType": "Background",
            "ThrottleInterval": 5, "AbandonProcessGroup": true,
            "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"]
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw integrationError("Invalid installation manifest")
    }
    return object
}

private func identical(_ a: [String: Any], _ b: [String: Any]) -> Bool {
    NSDictionary(dictionary: a).isEqual(to: b)
}

// The relay, launchd plist and resolver this checkout installs for `username`.
private func integrationPayloads(uid: uid_t, username: String) throws -> [String: Data] {
    let relay = try ownedBytes(try installerRepositoryRoot() + "/bin/latte-port-relay", uid: uid)
    let plist = try PropertyListSerialization.data(fromPropertyList: plistConfiguration(username: username), format: .xml, options: 0)
    return ["relay": relay, "plist": plist, "resolver": resolverBytes]
}

private func prepare(_ bundle: String, host: SystemHost) throws {
    guard host.euid() != host.rootUID else {
        throw integrationError("Prepare the installation as the ordinary installing user")
    }
    let uid = getuid()
    let username = try account(uid)
    let payloads = try integrationPayloads(uid: uid, username: username)
    guard mkdir(bundle, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    for name in ["relay", "plist", "resolver"] {
        try atomicWrite(payloads[name]!, to: bundle + "/" + name, mode: 0o600, prefix: ".caramel-")
    }
    let digests = payloads.mapValues { sha256(data: $0) }
    let manifest: [String: Any] = ["version": 1, "uid": Int(uid), "username": username, "sha256": digests]
    try atomicWrite(try canonicalJSON(manifest), to: bundle + "/manifest.json", mode: 0o600, prefix: ".caramel-")
    let review: [String: Any] = ["bundle": bundle, "installs": host.destinations,
                                 "runs_as": username, "sha256": digests]
    print(String(decoding: try canonicalJSON(review), as: UTF8.self), terminator: "")
}

private struct Bundle {
    let manifest: [String: Any]
    let payloads: [String: Data]
}

private func loadBundle(_ path: String) throws -> Bundle {
    guard let info = statOf(path), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          info.st_mode & 0o077 == 0, info.st_uid != 0 else {
        throw integrationError("Installation bundle must be a private, user-owned directory")
    }
    let manifest = try jsonObject(ownedBytes(path + "/manifest.json", uid: info.st_uid, privateFile: true))
    guard manifest["version"] as? Int == 1, manifest["uid"] as? Int == Int(info.st_uid) else {
        throw integrationError("Invalid installation manifest")
    }
    let username = try account(info.st_uid)
    guard manifest["username"] as? String == username else { throw integrationError("Installing account changed") }
    var payloads: [String: Data] = [:]
    for name in ["relay", "plist", "resolver"] {
        payloads[name] = try ownedBytes(path + "/" + name, uid: info.st_uid, privateFile: true)
    }
    let expectedDigests = payloads.mapValues { sha256(data: $0) }
    guard let digests = manifest["sha256"] as? [String: String], digests == expectedDigests else {
        throw integrationError("Installation artifact checksum mismatch")
    }
    let receivedPlist = try PropertyListSerialization.propertyList(from: payloads["plist"]!, options: [], format: nil)
    guard let config = receivedPlist as? [String: Any], identical(config, plistConfiguration(username: username)) else {
        throw integrationError("Port relay configuration differs from the fixed template")
    }
    guard payloads["resolver"] == resolverBytes else {
        throw integrationError("Resolver configuration differs from the fixed scope")
    }
    return Bundle(manifest: manifest, payloads: payloads)
}

private final class FixtureJobState {
    let descriptions: [String?]
    let log: String
    var index = 0
    init(descriptions: [String?], log: String) {
        self.descriptions = descriptions
        self.log = log
    }
}

private struct SystemHost {
    let rootUID: uid_t
    let destinations: [String: String]
    let receiptPath: String
    let trustedAncestorLimit: String
    let ports: [Int]
    private let fixture: FixtureJobState?

    static let production = SystemHost(rootUID: 0,
        destinations: ["relay": relayPath, "plist": "/Library/LaunchDaemons/dev.caramel.ports.plist",
                       "resolver": "/etc/resolver/caramel"],
        receiptPath: "/Library/Application Support/Caramel/local-integration.json",
        trustedAncestorLimit: "/", ports: [80, 443], fixture: nil)

    func euid() -> uid_t { fixture == nil ? geteuid() : rootUID }

    func jobDescription() throws -> String? {
        if let fixture {
            guard !fixture.descriptions.isEmpty else { return nil }
            let index = min(fixture.index, fixture.descriptions.count - 1)
            fixture.index += 1
            return fixture.descriptions[index]
        }
        let result = try run(["/bin/launchctl", "print", jobLabel], cwd: "/", environment: ProcessInfo.processInfo.environment, timeout: 20)
        return result.status == 0 ? result.stdout : nil
    }

    func launchctl(_ argv: [String]) throws {
        if let fixture {
            let line = argv.joined(separator: " ") + "\n"
            let fd = open(fixture.log, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            try line.utf8CString.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count - 1 {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - 1 - offset)
                    guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += count
                }
            }
            return
        }
        let result = try run(["/bin/launchctl"] + argv, cwd: "/", environment: ProcessInfo.processInfo.environment, timeout: 20)
        guard result.status == 0 else { throw integrationError(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func processLine(_ pid: String) throws -> String? {
        if fixture != nil { return nil }
        let result = try run(["/bin/ps", "-ww", "-p", pid, "-o", "uid=,command="], cwd: "/", environment: ProcessInfo.processInfo.environment, timeout: 10)
        return result.status == 0 ? result.stdout : nil
    }

}

private func capture(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .dotMatchesLineSeparators]) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).compactMap { match in
        guard match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[capture])
    }
}

private func verifyJob(_ description: String, host: SystemHost) throws {
    for (key, value) in [("path", host.destinations["plist"]!), ("program", host.destinations["relay"]!)] {
        guard capture("^\\s*" + key + " = ([^\\r\\n]+)$", in: description) == [value] else {
            throw integrationError("An existing launchd job with the same label is not owned by this installation")
        }
    }
    let arguments = capture("^\\s*arguments = \\{\\n(.*?)^\\s*\\}", in: description)
    guard arguments.count == 1,
          arguments[0].trimmingCharacters(in: .whitespacesAndNewlines) == host.destinations["relay"]! else {
        throw integrationError("The loaded port relay has unexpected arguments; it was preserved")
    }
}

private func secureParent(_ path: String, host: SystemHost) throws {
    guard let limitReal = realpath(host.trustedAncestorLimit, nil) else {
        throw integrationError("Unsafe system installation directory: \(host.trustedAncestorLimit)")
    }
    defer { free(limitReal) }
    let boundary = String(cString: limitReal)
    var missing: [String] = []
    var current = path
    while !FileManager.default.fileExists(atPath: current) {
        missing.append(current)
        let parent = (current as NSString).deletingLastPathComponent
        guard parent != current else { throw integrationError("Unsafe system installation directory: \(path)") }
        current = parent
    }
    for directory in missing.reversed() {
        guard mkdir(directory, 0o755) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    guard let real = realpath(path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { free(real) }
    let resolved = String(cString: real)
    guard resolved == boundary || resolved.hasPrefix(boundary == "/" ? "/" : boundary + "/") else {
        throw integrationError("Unsafe system installation directory: \(resolved)")
    }
    var ancestor = resolved
    while true {
        // `realpath` resolved aliases already, so `lstat` sees the actual directory.
        guard let info = statOf(ancestor), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == host.rootUID, info.st_mode & 0o022 == 0 else {
            throw integrationError("Unsafe system installation directory: \(ancestor)")
        }
        if ancestor == boundary { break }
        ancestor = (ancestor as NSString).deletingLastPathComponent
    }
}

private func systemWrite(_ path: String, data: Data, mode: mode_t, host: SystemHost) throws {
    try secureParent((path as NSString).deletingLastPathComponent, host: host)
    try atomicWrite(data, to: path, mode: mode, prefix: ".caramel-")
}

private func readReceipt(_ host: SystemHost) throws -> [String: Any]? {
    guard existing(host.receiptPath) else { return nil }
    return try jsonObject(ownedBytes(host.receiptPath, uid: host.rootUID, privateFile: true))
}

private func requireOwnedFiles(_ receipt: [String: Any], host: SystemHost) throws {
    guard let digests = receipt["sha256"] as? [String: String] else { throw integrationError("Invalid installation manifest") }
    for name in ["relay", "plist", "resolver"] {
        let path = host.destinations[name]!
        if existing(path) {
            let bytes = try ownedBytes(path, uid: host.rootUID)
            guard digests[name] == sha256(data: bytes) else {
                throw integrationError("Owned installation changed; preserving it: \(path)")
            }
        }
    }
}

private func reservePorts(_ host: SystemHost) throws -> [Int32] {
    var sockets: [Int32] = []
    do {
        for port in host.ports {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw integrationError("Port \(port) is occupied or unavailable; its service was preserved") }
            sockets.append(fd)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
            let status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard status == 0 else { throw integrationError("Port \(port) is occupied or unavailable; its service was preserved") }
        }
        return sockets
    } catch {
        sockets.forEach { _ = Darwin.close($0) }
        throw error
    }
}

private func awaitJob(_ uid: Int, host: SystemHost) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    var observed: String?
    while ProcessInfo.processInfo.systemUptime < deadline {
        if let description = try host.jobDescription(), !description.isEmpty {
            try verifyJob(description, host: host)
            if let pid = capture("^\\s*pid = (\\d+)$", in: description).first,
               let line = try host.processLine(pid) {
                let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                if parts.count == 2, parts[0] == String(uid), parts[1] == host.destinations["relay"]! {
                    if observed == pid { return }
                    observed = pid
                }
            }
        }
        Thread.sleep(forTimeInterval: 0.3)
    }
    throw integrationError("The unprivileged port relay did not become ready")
}

private func removeOwnedFiles(_ receipt: [String: Any], host: SystemHost) throws {
    try requireOwnedFiles(receipt, host: host)
    for name in ["relay", "plist", "resolver"] {
        let path = host.destinations[name]!
        if existing(path), unlink(path) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    if existing(host.receiptPath), unlink(host.receiptPath) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

private func apply(_ bundlePath: String, host: SystemHost) throws {
    guard host.euid() == host.rootUID else { throw integrationError("Apply requires macOS administrator authorization") }
    let bundle = try loadBundle(bundlePath)
    let old = try readReceipt(host)
    var reservations: [Int32] = []
    defer { reservations.forEach { _ = Darwin.close($0) } }
    if let old {
        guard identical(old, bundle.manifest) else {
            throw integrationError("A different Caramel integration is installed; uninstall it explicitly first")
        }
        try requireOwnedFiles(old, host: host)
        if let job = try host.jobDescription(), !job.isEmpty {
            try verifyJob(job, host: host)
        } else {
            reservations = try reservePorts(host)
        }
    } else {
        for name in ["relay", "plist", "resolver"] {
            let path = host.destinations[name]!
            if existing(path) { throw integrationError("Existing configuration was preserved: \(path)") }
        }
        if let job = try host.jobDescription(), !job.isEmpty {
            throw integrationError("An unowned launchd job already uses the Caramel label; it was preserved")
        }
        reservations = try reservePorts(host)
    }
    do {
        // Claim ownership before writing the payload, so a stopped installation is resumable.
        try systemWrite(host.receiptPath, data: canonicalJSON(bundle.manifest), mode: 0o600, host: host)
        for name in ["relay", "plist", "resolver"] {
            let path = host.destinations[name]!
            if !existing(path) {
                try systemWrite(path, data: bundle.payloads[name]!, mode: name == "relay" ? 0o755 : 0o644, host: host)
            }
        }
        reservations.forEach { _ = Darwin.close($0) }
        reservations.removeAll()
        if let job = try host.jobDescription(), !job.isEmpty {
            try verifyJob(job, host: host)
        } else {
            try host.launchctl(["bootstrap", "system", host.destinations["plist"]!])
        }
        try awaitJob(bundle.manifest["uid"] as! Int, host: host)
    } catch {
        if old == nil {
            if let job = try? host.jobDescription(), !job.isEmpty,
               (try? verifyJob(job, host: host)) != nil {
                try host.launchctl(["bootout", jobLabel])
            }
            try removeOwnedFiles(bundle.manifest, host: host)
        }
        throw error
    }
    print("Installed Caramel resolver and unprivileged standard-port relay.")
}

private func uninstall(_ host: SystemHost) throws {
    guard host.euid() == host.rootUID else { throw integrationError("Uninstall requires macOS administrator authorization") }
    guard let receipt = try readReceipt(host) else {
        print("No owned system integration is installed.")
        return
    }
    try requireOwnedFiles(receipt, host: host)
    if let job = try host.jobDescription(), !job.isEmpty {
        try verifyJob(job, host: host)
        try host.launchctl(["bootout", jobLabel])
    }
    try removeOwnedFiles(receipt, host: host)
    print("Removed only the recorded Caramel resolver and relay. User certificate trust is managed separately.")
}

// Compares each installed file with the one this checkout would install,
// reading only the world-readable system copies: "current", "stale" or
// "absent" per payload. Needs no administrator rights.
private func status(_ host: SystemHost) throws {
    let uid = getuid()
    let expected = try integrationPayloads(uid: uid, username: try account(uid))
    var states: [String: String] = [:]
    for (name, bytes) in expected {
        let installed = host.destinations[name]!
        if !existing(installed) {
            states[name] = "absent"
        } else {
            states[name] = sha256(data: try Data(contentsOf: URL(fileURLWithPath: installed))) == sha256(data: bytes) ? "current" : "stale"
        }
    }
    print(String(decoding: try canonicalJSON(states), as: UTF8.self))
}

@main
private enum LocalIntegrationInstaller {
    static func main() {
        do {
            try execute()
        } catch {
            let message = (error as? InstallerError)?.message ?? error.localizedDescription
            fputs("Caramel integration: \(message)\n", stderr)
            exit(1)
        }
    }

    static func execute() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let program = (CommandLine.arguments[0] as NSString).lastPathComponent
        let options = CommandLineOptions(
            program: program,
            usage: "\(program) [-h] {prepare,apply,uninstall,status} ...",
            description: "Prepare/review the fixed macOS DNS/port integration; apply requires root.\n\nCertificate trust is installed separately as the user, never by the root helper.\nNo project code is executed by this installer.",
            options: [("-h, --help", "show this help message and exit")])
        if args.first == "-h" || args.first == "--help" { options.help() }
        guard let command = args.first else { options.error("the following arguments are required: command") }
        let commands = ["prepare", "apply", "uninstall", "status"]
        let bare = ["uninstall", "status"].contains(command)
#if CARAMEL_INSTALLER_TESTING
        let hidden = ["test-validate", "test-verify-job"]
#else
        let hidden = [String]()
#endif
        guard commands.contains(command) || hidden.contains(command) else {
            options.error("argument command: invalid choice: '\(command)' (choose from 'prepare', 'apply', 'uninstall', 'status')")
        }
        if args.dropFirst().contains("-h") || args.dropFirst().contains("--help") {
            CommandLineOptions(program: program + " " + command,
                               usage: "\(program) \(command) [-h]" + (bare ? "" : " bundle"),
                               description: "", options: [("-h, --help", "show this help message and exit")]).help()
        }
        if args.count == 1 && !bare {
            options.error("the following arguments are required: bundle")
        }
        if args.count != (bare ? 1 : 2) {
            options.error("unrecognized arguments: \(args.dropFirst(bare ? 1 : 2).joined(separator: " "))")
        }
        if args.count == 2 && args[1].hasPrefix("-") {
            options.error("the following arguments are required: bundle")
        }
        let host: SystemHost
#if CARAMEL_INSTALLER_TESTING
        if let fixture = ProcessInfo.processInfo.environment["CARAMEL_INSTALLER_FIXTURE"], !fixture.isEmpty {
            host = try SystemHost.fixtureHost(fixture)
        } else {
            host = .production
        }
        if args.count == 2, args[0] == "test-validate" {
            _ = try loadBundle(args[1]); print("ok"); return
        }
        if args.count == 2, args[0] == "test-verify-job" {
            try verifyJob(String(contentsOfFile: args[1], encoding: .utf8), host: host)
            print("ok"); return
        }
#else
        host = .production
#endif
        if command == "prepare" {
            try prepare(URL(fileURLWithPath: args[1]).standardizedFileURL.path, host: host)
        } else if command == "apply" {
            try apply(URL(fileURLWithPath: args[1]).standardizedFileURL.path, host: host)
        } else if command == "status" {
            try status(host)
        } else {
            try uninstall(host)
        }
    }
}

#if CARAMEL_INSTALLER_TESTING
private extension SystemHost {
    static func fixtureHost(_ path: String) throws -> SystemHost {
        let values = try jsonObject(Data(contentsOf: URL(fileURLWithPath: path)))
        guard let rootUID = values["root_uid"] as? Int,
              let destinations = values["destinations"] as? [String: String],
              let receipt = values["receipt"] as? String,
              let systemRoot = values["system_root"] as? String,
              let ports = values["ports"] as? [Int],
              let jobs = values["jobs"] as? [Any], let log = values["log"] as? String else {
            throw integrationError("Invalid integration fixture")
        }
        let descriptions = try jobs.map { entry -> String? in
            if entry is NSNull { return nil }
            guard let text = entry as? String else { throw integrationError("Invalid integration fixture") }
            return text
        }
        return SystemHost(rootUID: uid_t(rootUID), destinations: destinations,
                          receiptPath: receipt, trustedAncestorLimit: systemRoot, ports: ports,
                          fixture: FixtureJobState(descriptions: descriptions, log: log))
    }
}
#endif
