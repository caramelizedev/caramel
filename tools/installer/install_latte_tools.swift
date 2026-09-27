import Foundation
import Darwin

private struct CoreDNSRelease {
    let version: String
    let url: String
    let archiveSHA256: String
    let binarySHA256: String
    let receipt: [String: Any]

    init(_ value: [String: Any]) throws {
        guard let version = value["version"] as? String,
              let url = value["url"] as? String,
              let archiveSHA256 = value["archive_sha256"] as? String,
              let binarySHA256 = value["binary_sha256"] as? String else {
            throw InstallerError(message: "invalid CoreDNS release manifest")
        }
        self.version = version
        self.url = url
        self.archiveSHA256 = archiveSHA256
        self.binarySHA256 = binarySHA256
        self.receipt = value
    }
}

private func pathExists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

private func pathInfo(_ path: String) -> stat? {
    var info = stat()
    return lstat(path, &info) == 0 ? info : nil
}

private func ownedToolDirectory(_ path: String) throws {
    if let info = pathInfo(path), (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
        throw InstallerError(message: "tool directory must not be a symlink")
    }
    if mkdir(path, 0o700) != 0 && errno != EEXIST {
        throw InstallerError(message: "\(path): \(String(cString: strerror(errno)))")
    }
    guard let info = pathInfo(path), (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
          info.st_uid == getuid(), (info.st_mode & 0o022) == 0 else {
        throw InstallerError(message: "tool directory must be owned and not writable by other users")
    }
}

private func temporaryDirectory(in parent: String, prefix: String) throws -> String {
    var template = Array((parent + "/" + prefix + "XXXXXX").utf8CString)
    guard mkdtemp(&template) != nil else {
        throw InstallerError(message: "could not create CoreDNS temporary directory: \(String(cString: strerror(errno)))")
    }
    return String(cString: template)
}

private func commandOutput(_ argv: [String]) throws -> String {
    let result = try run(argv, cwd: "/", environment: ProcessInfo.processInfo.environment, timeout: 600)
    guard result.status == 0 else {
        throw InstallerError(message: "\(argv[0]): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return result.stdout
}

private func inspectArchive(_ archive: String) throws {
    let environment = ProcessInfo.processInfo.environment
    let listing = try run(["/usr/bin/tar", "-tzf", archive], cwd: "/", environment: environment, timeout: 600)
    guard listing.status == 0, listing.stdout == "coredns\n" else {
        throw InstallerError(message: "unexpected CoreDNS archive contents")
    }
    let verbose = try run(["/usr/bin/tar", "-tvzf", archive], cwd: "/", environment: environment, timeout: 600)
    let fields = verbose.stdout.split(whereSeparator: { $0.isWhitespace })
    guard verbose.status == 0, verbose.stdout.first == "-", fields.count >= 6,
          let size = UInt64(fields[4]), size <= 128 * 1024 * 1024 else {
        throw InstallerError(message: "unexpected CoreDNS archive contents")
    }
}

private func verifiedExistingBinary(_ target: String, release: CoreDNSRelease) throws -> String {
    let binary = target + "/coredns"
    guard let directory = pathInfo(target),
          (directory.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
          directory.st_uid == getuid(), (directory.st_mode & 0o022) == 0,
          let file = pathInfo(binary), (file.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
          file.st_uid == getuid(), (file.st_mode & 0o022) == 0,
          try sha256(file: binary) == release.binarySHA256 else {
        throw InstallerError(message: "existing CoreDNS installation failed verification; preserved for inspection")
    }
    return binary
}

private func installArchive(_ archive: String, target: String, release: CoreDNSRelease) throws -> String {
    if let info = pathInfo(target), (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
        throw InstallerError(message: "tool destination must not be a symlink")
    }
    if pathExists(target) {
        return try verifiedExistingBinary(target, release: release)
    }
    guard let archiveInfo = pathInfo(archive),
          (archiveInfo.st_mode & mode_t(S_IFMT)) != mode_t(S_IFLNK),
          try sha256(file: archive) == release.archiveSHA256 else {
        throw InstallerError(message: "CoreDNS archive checksum failed; installation was not changed")
    }
    let parent = (target as NSString).deletingLastPathComponent
    try ownedToolDirectory(parent)
    let temp = try temporaryDirectory(in: parent, prefix: ".coredns-install-")
    defer { try? FileManager.default.removeItem(atPath: temp) }
    let stage = temp + "/payload"
    guard mkdir(stage, 0o700) == 0 else {
        throw InstallerError(message: "\(stage): \(String(cString: strerror(errno)))")
    }
    try inspectArchive(archive)
    _ = try commandOutput(["/usr/bin/tar", "-xzf", archive, "-C", stage, "coredns"])
    let binary = stage + "/coredns"
    guard let info = pathInfo(binary), (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
          info.st_size <= 128 * 1024 * 1024 else {
        throw InstallerError(message: "unexpected CoreDNS archive contents")
    }
    guard try sha256(file: binary) == release.binarySHA256 else {
        throw InstallerError(message: "CoreDNS binary checksum failed; installation was not changed")
    }
    guard chmod(binary, 0o755) == 0 else {
        throw InstallerError(message: "\(binary): \(String(cString: strerror(errno)))")
    }
    try atomicWrite(canonicalJSON(release.receipt), to: stage + "/receipt.json", mode: 0o600, prefix: ".receipt-")
    // Publish only the complete, verified payload on the same filesystem.
    guard rename(stage, target) == 0 else {
        throw InstallerError(message: "\(target): \(String(cString: strerror(errno)))")
    }
    return target + "/coredns"
}

private func releaseManifest(repository: String) throws -> CoreDNSRelease {
    let source: String
    #if CARAMEL_INSTALLER_TESTING
    if let fixture = ProcessInfo.processInfo.environment["CARAMEL_INSTALLER_FIXTURE"], !fixture.isEmpty {
        source = fixture
    } else {
        source = repository + "/tools/latte-darwin-arm64.json"
    }
    #else
    source = repository + "/tools/latte-darwin-arm64.json"
    #endif
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: source)))
    guard let manifest = object as? [String: Any], let entry = manifest["coredns"] as? [String: Any] else {
        throw InstallerError(message: "invalid CoreDNS release manifest")
    }
    return try CoreDNSRelease(entry)
}

@main
struct InstallLatteTools {
    static func main() {
        let cli = CommandLineOptions(program: "install-latte-tools", usage: "install-latte-tools [-h] [--archive ARCHIVE]", description: "Add the pinned DNS binary to the isolated contributor toolchain.\n\nCrystal, PostgreSQL, OpenSSL, and Caddy retain the toolchain experiment's mise lock. This supplements that installation; it is not the consumer installer.", options: [("-h, --help", "show this help message and exit"), ("--archive ARCHIVE", "use a previously downloaded pinned archive")])
        let args = Array(CommandLine.arguments.dropFirst())
        var archive: String?
        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "-h" || argument == "--help" { cli.help() }
            if argument == "--archive" {
                index += 1
                guard index < args.count, !args[index].hasPrefix("-") else {
                    cli.error("argument --archive: expected one argument")
                }
                archive = args[index]
            } else if argument.hasPrefix("--archive=") {
                archive = String(argument.dropFirst("--archive=".count))
            } else if argument.hasPrefix("-") {
                cli.error("unrecognized arguments: \(argument)")
            } else {
                cli.error("unrecognized arguments: \(argument)")
            }
            index += 1
        }
        #if arch(arm64) && os(macOS)
        #else
        cli.error("this provider supports Apple Silicon macOS")
        #endif
        guard let rootValue = ProcessInfo.processInfo.environment["CARAMEL_TOOLCHAIN_ROOT"], !rootValue.isEmpty else {
            cli.error("set CARAMEL_TOOLCHAIN_ROOT to the isolated contributor installation")
        }
        do {
            guard let resolvedRoot = realpath(rootValue, nil) else {
                throw InstallerError(message: "\(rootValue): \(String(cString: strerror(errno)))")
            }
            let root = String(cString: resolvedRoot)
            free(resolvedRoot)
            try ownedToolDirectory(root)
            let release = try releaseManifest(repository: try installerRepositoryRoot())
            var parent = root
            for component in ["data", "installs", "github-coredns-coredns"] {
                parent += "/" + component
                try ownedToolDirectory(parent)
            }
            let target = parent + "/" + release.version
            let binary: String
            if archive != nil || pathExists(target) {
                binary = try installArchive(archive ?? "unused", target: target, release: release)
            } else {
                let temp = try temporaryDirectory(in: parent, prefix: ".coredns-download-")
                defer { try? FileManager.default.removeItem(atPath: temp) }
                let downloaded = temp + "/coredns.tgz"
                try download(url: release.url, to: downloaded)
                binary = try installArchive(downloaded, target: target, release: release)
            }
            print("Verified CoreDNS \(release.version): \(binary)")
        } catch {
            let message = (error as? InstallerError)?.message ?? error.localizedDescription
            fputs("install-latte-tools: \(message)\n", stderr)
            exit(1)
        }
    }
}
