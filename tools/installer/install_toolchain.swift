import Foundation
import Darwin
import CryptoKit

private let receiptName = ".caramel-toolchain.json"
private let miseURL = "https://github.com/jdx/mise/releases/download/v2026.9.11/mise-v2026.9.11-macos-arm64"
private let miseSHA = "bbfd47ef65c2278c4e9ba09b523beb1019365a3c0b9c9fc60f686dc16f358e0f"
private let releaseCritical = [
    "bin/mise",
    "data/installs/github-crystal-lang-crystal/1.21.0/embedded/bin/crystal",
    "data/installs/github-crystal-lang-crystal/1.21.0/embedded/bin/shards",
    "data/installs/aqua-caddyserver-caddy/2.11.4/caddy",
    "data/installs/conda-postgresql/18.6/bin/postgres",
    "data/installs/conda-postgresql/18.6/bin/initdb",
    "data/installs/conda-postgresql/18.6/bin/pg_ctl",
    "data/installs/conda-postgresql/18.6/bin/psql",
    "data/installs/conda-openssl/3.6.4/bin/openssl",
    "data/installs/conda-openssl/3.6.4/lib/libssl.3.dylib",
    "data/installs/conda-openssl/3.6.4/lib/libcrypto.3.dylib",
    "data/installs/conda-pkgconf/3.0.7/bin/pkgconf",
    "data/installs/github-coredns-coredns/1.14.7/coredns"
]
private let releaseAliases = [
    "bin/shards": "../data/installs/github-crystal-lang-crystal/1.21.0/embedded/bin/shards",
    "bin/pkg-config": "../data/installs/conda-pkgconf/3.0.7/bin/pkgconf"
]
private let ownedDirectories = [
    "MISE_DATA_DIR": "data", "MISE_CACHE_DIR": "cache", "MISE_STATE_DIR": "state",
    "MISE_CONFIG_DIR": "config", "MISE_SYSTEM_CONFIG_DIR": "system-config",
    "MISE_SYSTEM_DATA_DIR": "system-data", "XDG_CACHE_HOME": "xdg-cache",
    "XDG_CONFIG_HOME": "xdg-config", "XDG_DATA_HOME": "xdg-data",
    "XDG_STATE_HOME": "xdg-state", "MAMBA_ROOT_PREFIX": "mamba",
    "CRYSTAL_CACHE_DIR": "crystal-cache"
]
private let preparedDirectories = [
    "bin", "data", "cache", "state", "config", "system-config", "system-data",
    "xdg-cache", "xdg-config", "xdg-data", "xdg-state", "mamba", "crystal-cache",
    "data/installs", "project", "launchers"
]
private let compilerEntry = """
#!/bin/sh
ROOT=$(CDPATH= cd -- "$(dirname -- "$(/bin/realpath -- "$0")")/.." && pwd -P) || exit 1
export CARAMEL_TOOLCHAIN_ROOT="$ROOT"
exec "$ROOT/launchers/crystal" "$@"
""" + "\n"

private func path(_ root: String, _ relative: String) -> String { root + "/" + relative }

private func info(_ file: String) -> stat? {
    var result = stat()
    return file.withCString { lstat($0, &result) } == 0 ? result : nil
}

private func exists(_ file: String) -> Bool { info(file) != nil }
private func isLink(_ file: String) -> Bool {
    guard let st = info(file) else { return false }
    return (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
}

private func directory(_ root: String, _ relative: String) throws {
    var current = root
    for component in relative.split(separator: "/") {
        current += "/" + component
        if !exists(current) && mkdir(current, 0o700) != 0 && errno != EEXIST {
            throw InstallerError(message: "cannot create directory: \(current): \(String(cString: strerror(errno)))")
        }
        try requireOwnedDirectory(current)
    }
}

private func readlinkValue(_ file: String) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let capacity = buffer.count - 1
    let count = file.withCString { readlink($0, &buffer, capacity) }
    return count >= 0 ? String(decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
}

private func checkedRun(_ argv: [String], cwd: String, environment: [String: String], timeout: TimeInterval, forwardOutput: Bool = false) throws -> (stdout: String, stderr: String) {
    let result = try run(argv, cwd: cwd, environment: environment, timeout: timeout)
    if forwardOutput {
        if !result.stdout.isEmpty { fputs(result.stdout, stdout) }
        if !result.stderr.isEmpty { fputs(result.stderr, stderr) }
    }
    guard result.status == 0 else {
        throw InstallerError(message: "Command \(argv) returned non-zero exit status \(result.status).")
    }
    return (result.stdout, result.stderr)
}

func providerEnvironment(root: String, inherited: [String: String]) throws -> [String: String] {
    var env: [String: String] = [:]
    for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
        if let value = inherited[key] { env[key] = value }
    }
    env.merge([
        "PATH": path(root, "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8", "TERM": "dumb", "MISE_COLOR": "0", "MISE_AUTO_ENV": "0",
        "MISE_ENV_CONF_D": "0", "MISE_OVERRIDE_TOOL_VERSIONS_FILENAMES": "none",
        "MISE_OVERRIDE_CONFIG_FILENAMES": "caramel-toolchain.toml", "MISE_CEILING_PATHS": root,
        "MISE_ENV": "", "MISE_NO_ENV": "1", "MISE_NO_HOOKS": "1", "MISE_NETRC": "0",
        "MISE_AUTO_INSTALL": "0", "MISE_PARANOID": "1", "MISE_LOCKFILE_PLATFORMS": "macos-arm64",
        "MISE_HTTP_TIMEOUT": "30s", "MISE_HTTP_DOWNLOAD_TIMEOUT": "3m", "MISE_HTTP_RETRIES": "1",
        "MISE_GLOBAL_CONFIG_FILE": path(root, "config/empty.toml"),
        "MISE_SYSTEM_CONFIG_FILE": path(root, "system-config/empty.toml")
    ]) { _, new in new }
    for (variable, relative) in ownedDirectories {
        try directory(root, relative)
        env[variable] = path(root, relative)
    }
    for relative in ["config/empty.toml", "system-config/empty.toml"] {
        let file = path(root, relative)
        if !exists(file) {
            try atomicWrite(Data(), to: file, mode: 0o600, prefix: ".install-")
        } else {
            try requireOwnedFile(file)
        }
    }
    return env
}

private struct InstallerFixture {
    let payloads: [String: Data]?
    let critical: [String]?
    let aliases: [String: String]?
    let provider: String?
    // Where a test installation records its pointer instead of the checkout.
    let pointer: String?

    static func load() throws -> InstallerFixture? {
        #if CARAMEL_INSTALLER_TESTING
        guard let file = ProcessInfo.processInfo.environment["CARAMEL_INSTALLER_FIXTURE"] else { return nil }
        guard let dictionary = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any] else {
            throw InstallerError(message: "installer fixture must be a JSON object")
        }
        let payloads = (dictionary["payloads"] as? [String: String])?.mapValues { Data($0.utf8) }
        return InstallerFixture(payloads: payloads, critical: dictionary["critical"] as? [String], aliases: dictionary["aliases"] as? [String: String], provider: dictionary["provider"] as? String, pointer: dictionary["pointer"] as? String)
        #else
        return nil
        #endif
    }
}

private func canonicalInstallationRoot(_ supplied: String) throws -> String {
    let expanded = (supplied as NSString).expandingTildeInPath
    let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
    var parts: [Substring] = []
    for component in absolute.split(separator: "/") {
        if component == ".." {
            if !parts.isEmpty { parts.removeLast() }
        } else if component != "." {
            parts.append(component)
        }
    }
    let lexical = "/" + parts.joined(separator: "/")
    if isLink(lexical) { throw InstallerError(message: "installation root cannot be a symlink") }
    var ancestor = lexical
    var missing: [String] = []
    while !exists(ancestor) && ancestor != "/" {
        missing.append((ancestor as NSString).lastPathComponent)
        ancestor = (ancestor as NSString).deletingLastPathComponent
    }
    guard let resolved = ancestor.withCString({ Darwin.realpath($0, nil) }) else {
        throw InstallerError(message: "cannot resolve installation root: " + lexical)
    }
    defer { free(resolved) }
    var canonical = String(cString: resolved)
    for component in missing.reversed() {
        canonical += (canonical == "/" ? "" : "/") + component
    }
    return canonical
}

private final class ToolchainInstallation {
    let root: String
    let payloads: [String: Data]
    let selection: [String: String]
    let critical: [String]
    let aliases: [String: String]
    let fixture: InstallerFixture?
    private var lock: ExclusiveLock?
    private var state: [String: Any] = [:]

    init(root supplied: String) throws {
        root = try canonicalInstallationRoot(supplied)
        fixture = try InstallerFixture.load()
        critical = fixture?.critical ?? releaseCritical
        aliases = fixture?.aliases ?? releaseAliases
        payloads = try ToolchainInstallation.releasePayloads(fixture: fixture)
        selection = payloads.mapValues { sha256(data: $0) }
    }

    // The authored files this toolchain release installs, read from the
    // checkout (or supplied by a test fixture).
    static func releasePayloads(fixture: InstallerFixture?) throws -> [String: Data] {
        if let payloads = fixture?.payloads { return payloads }
        let repo = try installerRepositoryRoot()
        let sources = [
            "project/caramel-toolchain.toml": "tools/toolchain/caramel-toolchain.toml",
            "project/mise.lock": "tools/toolchain/mise.lock",
            "project/smoke.cr": "tools/toolchain/smoke.cr",
            "launchers/crystal": "scripts/crystal",
            "launchers/shards": "scripts/shards",
            "latte-darwin-arm64.json": "tools/latte-darwin-arm64.json"
        ]
        var authored: [String: Data] = [:]
        for (target, source) in sources {
            authored[target] = try Data(contentsOf: URL(fileURLWithPath: path(repo, source)))
        }
        authored["bin/crystal"] = Data(compilerEntry.utf8)
        authored["config/empty.toml"] = Data()
        authored["system-config/empty.toml"] = Data()
        return authored
    }

    func claim() throws {
        if let st = info(root) {
            if (st.st_mode & mode_t(S_IFMT)) != mode_t(S_IFDIR) || st.st_uid != getuid() {
                throw InstallerError(message: "installation root must be an owned directory")
            }
            let children = try FileManager.default.contentsOfDirectory(atPath: root)
            if !children.contains(receiptName) && children.contains(where: { $0 != ".install.lock" }) {
                throw InstallerError(message: "refusing a nonempty directory without a Caramel receipt")
            }
            if !children.isEmpty && (st.st_mode & 0o077) != 0 {
                throw InstallerError(message: "installation root must be private (mode 0700)")
            }
        } else {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if chmod(root, 0o700) != 0 { throw InstallerError(message: "cannot set private installation root: \(root)") }
        lock = try ExclusiveLock(path: path(root, ".install.lock"), message: "another Caramel toolchain installer is already running")
        let receipt = path(root, receiptName)
        if exists(receipt) {
            try requireOwnedFile(receipt)
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: receipt))) as? [String: Any] else {
                throw InstallerError(message: "installation receipt must be an object")
            }
            state = object
            if state["root"] as? String != root { throw InstallerError(message: "installation was moved; install into a fresh prefix") }
            if state["version"] as? Int != 1 || state["selection"] as? [String: String] != selection {
                throw InstallerError(message: "installation receipt differs from this toolchain release")
            }
            if !["installing", "complete"].contains(state["status"] as? String ?? "") {
                throw InstallerError(message: "unrecognized installation state")
            }
        } else {
            state = ["version": 1, "root": root, "selection": selection, "status": "installing"]
            try save()
        }
    }

    private func save() throws {
        try atomicWrite(try canonicalJSON(state), to: path(root, receiptName), mode: 0o600, prefix: ".install-")
    }

    func prepare() throws {
        for relative in preparedDirectories { try directory(root, relative) }
        for (name, data) in payloads.sorted(by: { $0.key < $1.key }) {
            let file = path(root, name)
            let parent = (name as NSString).deletingLastPathComponent
            if parent != "." { try directory(root, parent) }
            if exists(file) {
                try requireOwnedFile(file)
                if try Data(contentsOf: URL(fileURLWithPath: file)) != data {
                    throw InstallerError(message: "authored toolchain file differs; preserved: " + name)
                }
            } else {
                try atomicWrite(data, to: file, mode: name.hasPrefix("bin/") || name.hasPrefix("launchers/") ? 0o700 : 0o600, prefix: ".install-")
            }
        }
    }

    private func artifactHashes() throws -> [String: String] {
        var hashes: [String: String] = [:]
        for name in critical {
            let file = path(root, name)
            var parent = (file as NSString).deletingLastPathComponent
            while parent != root && parent != "/" {
                if isLink(parent) { throw InstallerError(message: "artifact parent cannot be a symlink: " + parent) }
                parent = (parent as NSString).deletingLastPathComponent
            }
            try requireOwnedFile(file)
            hashes[name] = try sha256(file: file)
        }
        return hashes
    }

    private func verifyAliases() throws {
        for (name, target) in aliases {
            let alias = path(root, name)
            guard let st = info(alias), (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK),
                  st.st_uid == getuid(), readlinkValue(alias) == target else {
                throw InstallerError(message: "toolchain alias verification failed: " + name)
            }
        }
    }

    func verified() throws -> Bool {
        if state["status"] as? String != "complete" { return false }
        guard let recorded = state["artifacts"] as? [String: String], Set(recorded.keys) == Set(critical) else {
            throw InstallerError(message: "toolchain artifact inventory verification failed")
        }
        for (name, data) in payloads {
            let file = path(root, name)
            try requireOwnedFile(file)
            if try Data(contentsOf: URL(fileURLWithPath: file)) != data {
                throw InstallerError(message: "toolchain configuration verification failed: " + name)
            }
        }
        if try artifactHashes() != recorded {
            throw InstallerError(message: "toolchain artifact verification failed; preserve this prefix for inspection")
        }
        try verifyAliases()
        return true
    }

    func complete() throws {
        try verifyAliases()
        state["artifacts"] = try artifactHashes()
        state["status"] = "complete"
        try save()
    }

    func fixtureProvider() throws -> Bool {
        #if CARAMEL_INSTALLER_TESTING
        if fixture?.provider == "fail" { throw InstallerError(message: "fixture provider failed") }
        if fixture?.provider == "create-critical" {
            for name in critical {
                let file = path(root, name)
                let parent = (name as NSString).deletingLastPathComponent
                if parent != "." { try directory(root, parent) }
                if !exists(file) { try atomicWrite(Data("fixture\n".utf8), to: file, mode: 0o700, prefix: ".install-") }
            }
            for (name, target) in aliases {
                let alias = path(root, name)
                if !exists(alias) && symlink(target, alias) != 0 {
                    throw InstallerError(message: "cannot create tool alias: " + name)
                }
            }
            return true
        }
        #endif
        return false
    }

    func installPayloads(miseBinary: String?) throws {
        if try fixtureProvider() { return }
        let mise = path(root, "bin/mise")
        if !exists(mise) {
            let temp = path(root, ".mise-download-" + UUID().uuidString)
            try directory(root, (temp as NSString).lastPathComponent)
            defer { try? FileManager.default.removeItem(atPath: temp) }
            let downloaded = path(temp, "mise")
            if let local = miseBinary {
                try FileManager.default.copyItem(atPath: local, toPath: downloaded)
            } else {
                try download(url: miseURL, to: downloaded)
            }
            if try sha256(file: downloaded) != miseSHA { throw InstallerError(message: "mise checksum verification failed") }
            try atomicWrite(Data(contentsOf: URL(fileURLWithPath: downloaded)), to: mise, mode: 0o700, prefix: ".install-")
        }
        try requireOwnedFile(mise)
        if try sha256(file: mise) != miseSHA {
            throw InstallerError(message: "existing mise checksum verification failed; preserved")
        }
        var env = try providerEnvironment(root: root, inherited: ProcessInfo.processInfo.environment)
        _ = try checkedRun([mise, "trust", path(root, "project/caramel-toolchain.toml")], cwd: path(root, "project"), environment: env, timeout: 900, forwardOutput: true)
        _ = try checkedRun([mise, "install", "--locked"], cwd: path(root, "project"), environment: env, timeout: 900, forwardOutput: true)
        for (name, target) in aliases {
            let alias = path(root, name)
            if exists(alias) {
                if !isLink(alias) || readlinkValue(alias) != target {
                    throw InstallerError(message: "tool alias conflicts with existing file: " + name)
                }
            } else if symlink(target, alias) != 0 {
                throw InstallerError(message: "cannot create tool alias: " + name)
            }
        }
        env["CARAMEL_TOOLCHAIN_ROOT"] = root
        let repo = try installerRepositoryRoot()
        _ = try checkedRun([path(repo, "bin/install-latte-tools")], cwd: root, environment: env, timeout: 650, forwardOutput: true)
        _ = try checkedRun([path(root, "bin/crystal"), "build", path(root, "project/smoke.cr"), "-o", path(root, "project/smoke")], cwd: path(root, "project"), environment: env, timeout: 180, forwardOutput: true)
        _ = try checkedRun([path(root, "project/smoke")], cwd: root, environment: env, timeout: 15, forwardOutput: true)
        try verifyNativeTools(environment: env)
    }

    private func verifyNativeTools(environment: [String: String]) throws {
        let installs = path(root, "data/installs")
        let probes: [([String], String)] = [
            ([path(installs, "github-crystal-lang-crystal/1.21.0/embedded/bin/crystal"), "--version"], "Crystal 1.21.0"),
            ([path(installs, "github-crystal-lang-crystal/1.21.0/embedded/bin/shards"), "--version"], "Shards 0.20.0"),
            ([path(installs, "aqua-caddyserver-caddy/2.11.4/caddy"), "version"], "v2.11.4"),
            ([path(installs, "conda-postgresql/18.6/bin/postgres"), "--version"], "postgres (PostgreSQL) 18.6"),
            ([path(installs, "conda-postgresql/18.6/bin/initdb"), "--version"], "initdb (PostgreSQL) 18.6"),
            ([path(installs, "conda-postgresql/18.6/bin/pg_ctl"), "--version"], "pg_ctl (PostgreSQL) 18.6"),
            ([path(installs, "conda-postgresql/18.6/bin/psql"), "--version"], "psql (PostgreSQL) 18.6"),
            ([path(installs, "conda-openssl/3.6.4/bin/openssl"), "version"], "OpenSSL 3.6.4"),
            ([path(installs, "conda-pkgconf/3.0.7/bin/pkgconf"), "--version"], "3.0.7"),
            ([path(installs, "github-coredns-coredns/1.14.7/coredns"), "-version"], "CoreDNS-1.14.7"),
            ([path(root, "project/smoke")], "{\"message\":\"Caramel\",\"regex\":\"0\"}")
        ]
        var evidence: [[String: Any]] = []
        for (command, expected) in probes {
            var probeEnv = environment
            probeEnv["DYLD_PRINT_LIBRARIES"] = "1"
            let result = try checkedRun(command, cwd: root, environment: probeEnv, timeout: 20)
            let libraries = try verifyNativeOutput(stdout: result.stdout, stderr: result.stderr, succeeded: true, expected: expected, root: root, command: command[0])
            evidence.append(["command": command, "output": result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "libraries": libraries])
        }
        try atomicWrite(try canonicalJSON(evidence), to: path(root, "project/native-verification.json"), mode: 0o600, prefix: ".install-")
    }
}

private let dyldLibraryPattern = try! NSRegularExpression(pattern: #"^dyld\[\d+\]: <[0-9A-Fa-f-]+> (/.+)$"#)

func verifyNativeOutput(stdout: String, stderr: String, succeeded: Bool, expected: String, root: String, command: String) throws -> [String] {
    if !succeeded { throw InstallerError(message: "native tool execution failed: " + command) }
    if !stdout.hasPrefix(expected) { throw InstallerError(message: "native tool version/output differs: " + command) }
    let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
    var libraries = Set<String>()
    for line in stderr.components(separatedBy: .newlines) {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = dyldLibraryPattern.firstMatch(in: line, range: range),
              let captured = Range(match.range(at: 1), in: line) else { continue }
        let resolved = URL(fileURLWithPath: String(line[captured])).resolvingSymlinksInPath().path
        if ![resolvedRoot + "/", "/usr/lib/", "/System/Library/", "/Library/Apple/System/Library/"].contains(where: { resolved.hasPrefix($0) }) {
            throw InstallerError(message: "native tool loaded a library outside Caramel or macOS: " + resolved)
        }
        libraries.insert(resolved)
    }
    if libraries.isEmpty { throw InstallerError(message: "native library evidence is unavailable: " + command) }
    return libraries.sorted()
}

private func preflight() throws {
    #if !arch(arm64) || !os(macOS)
    throw InstallerError(message: "this toolchain supports Apple Silicon macOS")
    #endif
    for args in [["/usr/bin/xcrun", "--find", "clang"], ["/usr/bin/xcrun", "--show-sdk-path"]] {
        let output = try checkedRun(args, cwd: "/", environment: ProcessInfo.processInfo.environment, timeout: 15).stdout
        let destination = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if destination.isEmpty || !FileManager.default.fileExists(atPath: destination) {
            throw InstallerError(message: "Apple Command Line Tools and a usable macOS SDK are required")
        }
    }
}

// Caramel's state directory; toolchains live in its toolchains/ directory
// unless --root chooses another place.
private func caramelHome() -> String {
    if let home = ProcessInfo.processInfo.environment["CARAMEL_HOME"], !home.isEmpty {
        return (home as NSString).expandingTildeInPath
    }
    return path(NSHomeDirectory(), "Library/Application Support/Caramel")
}

// The checkout's .caramel-toolchain, which every Caramel command in the
// checkout reads. A test installation uses its fixture's pointer, if any.
private func pointerPath(_ fixture: InstallerFixture?) throws -> String? {
    #if CARAMEL_INSTALLER_TESTING
    return fixture?.pointer
    #else
    return path(try installerRepositoryRoot(), ".caramel-toolchain")
    #endif
}

private func record(_ installation: ToolchainInstallation) throws {
    guard let pointer = try pointerPath(installation.fixture) else { return }
    try atomicWrite(Data((installation.root + "\n").utf8), to: pointer, mode: 0o644, prefix: ".caramel-toolchain-")
    print("Recorded in " + pointer + "; Caramel commands in this checkout use this toolchain.")
}

// Without --root: the toolchain the checkout already records, when its
// receipt is for this release (so a rerun verifies or resumes it), otherwise
// a new directory named for this release in Caramel's toolchains directory.
private func defaultRoot() throws -> String {
    let fixture = try InstallerFixture.load()
    let selection = try ToolchainInstallation.releasePayloads(fixture: fixture).mapValues { sha256(data: $0) }
    if let pointer = try pointerPath(fixture),
       let text = try? String(contentsOfFile: pointer, encoding: .utf8),
       let recorded = text.split(separator: "\n").first.map({ String($0).trimmingCharacters(in: .whitespaces) }),
       recorded.hasPrefix("/"),
       let receipt = try? Data(contentsOf: URL(fileURLWithPath: path(recorded, receiptName))),
       let state = try? JSONSerialization.jsonObject(with: receipt) as? [String: Any],
       state["selection"] as? [String: String] == selection {
        return recorded
    }
    return path(caramelHome(), "toolchains/" + String(sha256(data: try canonicalJSON(selection)).prefix(12)))
}

private func install(root supplied: String?, offline: Bool, miseBinary: String?) throws {
    try preflight()
    let root = try supplied ?? defaultRoot()
    let expanded = (root as NSString).expandingTildeInPath
    if offline && !FileManager.default.fileExists(atPath: path(expanded, receiptName)) {
        throw InstallerError(message: "offline use requires a completed verified installation")
    }
    let installation = try ToolchainInstallation(root: root)
    try installation.claim()
    if try installation.verified() {
        print("Verified installed Caramel toolchain: " + installation.root)
        try record(installation)
        return
    }
    if offline { throw InstallerError(message: "offline use requires a completed verified installation") }
    try installation.prepare()
    try installation.installPayloads(miseBinary: miseBinary)
    try installation.prepare()
    try installation.complete()
    print("Installed and verified Caramel toolchain: " + installation.root)
    try record(installation)
}

@main
struct ToolchainInstaller {
    static func main() {
        installInterruptHandler(message: "Installation interrupted. Rerun the same command to resume.")
        let options = CommandLineOptions(
            program: "install-toolchain",
            usage: "install-toolchain [-h] [--root ROOT] [--offline] [--mise-binary MISE_BINARY]",
            description: "Install Caramel's pinned Apple Silicon tools into one private, durable prefix and record it in this checkout's .caramel-toolchain.\n\nThis component installs no system services, DNS, certificates, or databases.\nIt requires Apple's Command Line Tools (clang, Swift and a macOS SDK).",
            options: [("-h, --help", "show this help message and exit"), ("--root ROOT", "installation directory (default: the toolchain this checkout records, if it is this release; otherwise a directory named for this release in Caramel's toolchains directory)"), ("--offline", "verify and reuse a completed installation without downloads"), ("--mise-binary MISE_BINARY", "reuse a local mise binary after verifying the pinned SHA-256")]
        )
        let args = Array(CommandLine.arguments.dropFirst())
        #if CARAMEL_INSTALLER_TESTING
        if let command = args.first, command == "test-probe" || command == "test-environment" {
            do { try testCommand(args) } catch {
                fputs("install-toolchain: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        #endif
        var root: String?
        var miseBinary: String?
        var offline = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-h" || arg == "--help" { options.help() }
            if arg == "--offline" { offline = true }
            else if arg == "--root" || arg == "--mise-binary" {
                index += 1
                if index >= args.count { options.error("argument \(arg): expected one argument") }
                if arg == "--root" { root = args[index] } else { miseBinary = args[index] }
            } else if arg.hasPrefix("-") { options.error("unrecognized arguments: " + arg) }
            else { options.error("unrecognized arguments: " + arg) }
            index += 1
        }
        do { try install(root: root, offline: offline, miseBinary: miseBinary) }
        catch {
            let message = (error as? InstallerError)?.message ?? error.localizedDescription
            fputs("install-toolchain: \(message)\n", stderr)
            exit(1)
        }
    }
}

#if CARAMEL_INSTALLER_TESTING
private func testCommand(_ args: [String]) throws {
    var values: [String: String] = [:]
    var failed = false
    var index = 1
    while index < args.count {
        if args[index] == "--failed" { failed = true; index += 1; continue }
        guard args[index].hasPrefix("--"), index + 1 < args.count else {
            throw InstallerError(message: "invalid test arguments")
        }
        values[args[index]] = args[index + 1]
        index += 2
    }
    guard let root = values["--root"] else { throw InstallerError(message: "missing --root") }
    if args[0] == "test-environment" {
        let environment = try providerEnvironment(root: root, inherited: ProcessInfo.processInfo.environment)
        print(String(decoding: try canonicalJSON(environment), as: UTF8.self), terminator: "")
    } else {
        guard let expected = values["--expected"], let output = values["--stdout"], let errors = values["--stderr"] else {
            throw InstallerError(message: "missing test-probe arguments")
        }
        let libraries = try verifyNativeOutput(stdout: try String(contentsOfFile: output, encoding: .utf8), stderr: try String(contentsOfFile: errors, encoding: .utf8), succeeded: !failed, expected: expected, root: root, command: "test-probe")
        print(String(decoding: try canonicalJSON(libraries), as: UTF8.self), terminator: "")
    }
}
#endif
