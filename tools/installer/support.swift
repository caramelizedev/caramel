import Foundation
import CryptoKit
import Darwin

struct InstallerError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func sha256(data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func sha256(file path: String) throws -> String {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    var digest = SHA256()
    while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
        digest.update(data: chunk)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

func requireOwnedDirectory(_ path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
        throw InstallerError(message: "expected an owned directory (no symlink): \(path)")
    }
}

func requireOwnedFile(_ path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
        throw InstallerError(message: "expected an owned regular file (no symlink): \(path)")
    }
}

func atomicWrite(_ data: Data, to path: String, mode: mode_t = 0o600, prefix: String = ".install-") throws {
    let directory = (path as NSString).deletingLastPathComponent
    var template = Array((directory as NSString).appendingPathComponent(prefix + "XXXXXX").utf8CString)
    let fd = mkstemp(&template)
    guard fd >= 0 else { throw InstallerError(message: "could not create temporary file: \(path)") }
    let temporary = String(cString: template)
    var published = false
    defer {
        _ = close(fd)
        if !published { _ = unlink(temporary) }
    }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw InstallerError(message: "could not write temporary file: \(path)") }
            offset += written
        }
    }
    guard fsync(fd) == 0, fchmod(fd, mode) == 0, rename(temporary, path) == 0 else {
        throw InstallerError(message: "could not publish file: \(path)")
    }
    published = true
}

final class ExclusiveLock {
    private let descriptor: Int32

    init(path: String, message: String) throws {
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw InstallerError(message: "could not open installation lock: \(path)") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            _ = close(fd)
            throw InstallerError(message: "expected an owned regular file (no symlink): \(path)")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(fd)
            throw InstallerError(message: errno == EWOULDBLOCK ? message : "could not lock installation: \(path)")
        }
        descriptor = fd
    }

    deinit { _ = close(descriptor) }
}

private let runningChildLock = NSLock()
private var runningChild: Process?
private var interruptSource: DispatchSourceSignal?

func installInterruptHandler(message: String) {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.global())
    source.setEventHandler {
        runningChildLock.lock()
        let child = runningChild
        runningChildLock.unlock()
        if let child, child.isRunning { child.terminate() }
        fputs(message + "\n", stderr)
        _exit(130)
    }
    source.resume()
    interruptSource = source
}

func run(_ argv: [String], cwd: String, environment: [String: String], timeout: TimeInterval) throws -> (status: Int32, stdout: String, stderr: String) {
    guard let executable = argv.first else { throw InstallerError(message: "empty command") }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = Array(argv.dropFirst())
    child.currentDirectoryURL = URL(fileURLWithPath: cwd)
    child.environment = environment
    let output = Pipe()
    let errors = Pipe()
    child.standardOutput = output
    child.standardError = errors
    child.standardInput = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    child.terminationHandler = { _ in finished.signal() }
    try child.run()
    runningChildLock.lock()
    runningChild = child
    runningChildLock.unlock()
    defer {
        runningChildLock.lock()
        if runningChild === child { runningChild = nil }
        runningChildLock.unlock()
    }
    let readers = DispatchGroup()
    var stdout = Data()
    var stderrData = Data()
    readers.enter()
    DispatchQueue.global().async {
        stdout = output.fileHandleForReading.readDataToEndOfFile()
        readers.leave()
    }
    readers.enter()
    DispatchQueue.global().async {
        stderrData = errors.fileHandleForReading.readDataToEndOfFile()
        readers.leave()
    }
    if finished.wait(timeout: .now() + timeout) == .timedOut {
        if child.isRunning { child.terminate() }
        if finished.wait(timeout: .now() + 2) == .timedOut {
            _ = kill(child.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 2)
        }
        output.fileHandleForReading.closeFile()
        errors.fileHandleForReading.closeFile()
        throw InstallerError(message: "command timed out after \(Int(timeout)) seconds: \(executable)")
    }
    readers.wait()
    return (child.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderrData, as: UTF8.self))
}

func download(url: String, to path: String) throws {
    let command = ["/usr/bin/curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "15", "--max-time", "180", "--retry", "2", "--output", path, url]
    let result = try run(command, cwd: FileManager.default.currentDirectoryPath, environment: ProcessInfo.processInfo.environment, timeout: 600)
    guard result.status == 0 else { throw InstallerError(message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

func canonicalJSON(_ object: Any) throws -> Data {
    var bytes = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    bytes.append(0x0a)
    return bytes
}

func installerRepositoryRoot() throws -> String {
    var length: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &length)
    var buffer = [CChar](repeating: 0, count: Int(length))
    guard _NSGetExecutablePath(&buffer, &length) == 0, let resolved = realpath(buffer, nil) else {
        throw InstallerError(message: "could not resolve installer executable")
    }
    defer { free(resolved) }
    let binary = String(cString: resolved)
    let directory = (binary as NSString).deletingLastPathComponent
    let bin = (directory as NSString).lastPathComponent == "test" ? (directory as NSString).deletingLastPathComponent : directory
    return (bin as NSString).deletingLastPathComponent
}

// The checkout's toolchain, found the way every Caramel command finds it:
// CARAMEL_TOOLCHAIN_ROOT when set, otherwise the checkout's
// .caramel-toolchain, which scripts/install-toolchain writes.
func caramelToolchainRoot() throws -> String {
    if let value = ProcessInfo.processInfo.environment["CARAMEL_TOOLCHAIN_ROOT"], !value.isEmpty {
        return value
    }
    let pointer = try installerRepositoryRoot() + "/.caramel-toolchain"
    var st = stat()
    guard lstat(pointer, &st) == 0 else {
        throw InstallerError(message: "no Caramel toolchain is installed for this checkout; run scripts/install-toolchain")
    }
    guard (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), (st.st_mode & 0o022) == 0 else {
        throw InstallerError(message: "\(pointer) must be a regular file you own that no one else can write")
    }
    let text = try String(contentsOfFile: pointer, encoding: .utf8)
    let root = String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "").trimmingCharacters(in: .whitespaces)
    guard root.hasPrefix("/") else {
        throw InstallerError(message: "\(pointer) must name an absolute toolchain directory")
    }
    return root
}

struct CommandLineOptions {
    let program: String
    let usage: String
    let description: String
    let options: [(String, String)]

    func help() -> Never {
        print("usage: \(usage)\n\n\(description)\n\noptions:")
        for (name, explanation) in options { print("  \(name)  \(explanation)") }
        exit(0)
    }

    func error(_ message: String) -> Never {
        fputs("usage: \(usage)\n\(program): error: \(message)\n", stderr)
        exit(2)
    }
}
