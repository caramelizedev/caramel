import Darwin
import Dispatch
import Foundation

// launch_activate_socket is declared in launch.h.  The SDK imports its
// nullable out-pointer as a non-optional pointer, which makes a direct call
// needlessly easy to misuse.  Keep the C ABI explicit and free launchd's
// returned array exactly once.
@_silgen_name("launch_activate_socket")
private func latteLaunchActivateSocket(
    _ name: UnsafePointer<CChar>,
    _ fds: UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>,
    _ count: UnsafeMutablePointer<Int>
) -> Int32

private let productionHTTPPort: UInt16 = 80
private let productionHTTPSPort: UInt16 = 443
private let productionHTTPDestination: UInt16 = 18_080
private let productionHTTPSDestination: UInt16 = 18_443

private let maxActiveConnections = 128
private let readChunkSize = 16 * 1024
private let maxReadChunksPerCallback = 32
private let maxAcceptsPerCallback = 32
private let maximumBufferedBytes = 256 * 1024
private let resumeReadingBelowBytes = 128 * 1024
private let connectTimeoutSeconds: Int = 3
private let idleTimeoutSeconds: Int = 60
private let maximumConnectionLifetimeSeconds: Int = 10 * 60

private enum RelayError: Error, CustomStringConvertible {
    case usage(String)
    case system(String)
    case invalidInheritedSocket(String)

    var description: String {
        switch self {
        case let .usage(message): return "usage error: \(message)"
        case let .system(message): return "system error: \(message)"
        case let .invalidInheritedSocket(message): return "invalid launchd socket: \(message)"
        }
    }
}

private struct Destination {
    let port: UInt16
}

private struct RelayConfiguration {
    let httpListenerPort: UInt16?
    let httpsListenerPort: UInt16?
    let httpDestination: Destination
    let httpsDestination: Destination

    var isTestMode: Bool { httpListenerPort != nil }

    static func parse(arguments: ArraySlice<String>) throws -> RelayConfiguration {
        if arguments.isEmpty {
            return RelayConfiguration(
                httpListenerPort: nil,
                httpsListenerPort: nil,
                httpDestination: Destination(port: productionHTTPDestination),
                httpsDestination: Destination(port: productionHTTPSDestination)
            )
        }

        guard arguments.first == "--test-listen" else {
            throw RelayError.usage("the only alternate mode is --test-listen HTTPPORT HTTPSPORT HTTPDEST HTTPSDEST")
        }
        guard arguments.count == 5 else {
            throw RelayError.usage("--test-listen requires HTTPPORT HTTPSPORT HTTPDEST HTTPSDEST")
        }
        let values = arguments.dropFirst().map { argument -> UInt16? in
            guard let value = Int(argument), value >= 1024, value <= Int(UInt16.max) else {
                return nil
            }
            return UInt16(value)
        }
        guard values.count == 4, values.allSatisfy({ $0 != nil }) else {
            throw RelayError.usage("test ports must be distinct TCP loopback ports from 1024 through 65535")
        }
        let ports = values.compactMap { $0 }
        guard Set(ports).count == ports.count else {
            throw RelayError.usage("test ports must be distinct")
        }
        return RelayConfiguration(
            httpListenerPort: ports[0],
            httpsListenerPort: ports[1],
            httpDestination: Destination(port: ports[2]),
            httpsDestination: Destination(port: ports[3])
        )
    }
}

private func posixMessage(_ error: Int32 = errno) -> String {
    String(cString: strerror(error))
}

private func makeLoopbackAddress(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    "127.0.0.1".withCString { value in
        _ = inet_pton(AF_INET, value, &address.sin_addr)
    }
    return address
}

private func setNonBlocking(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFL, 0)
    guard flags >= 0 else { return false }
    return fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
}

private func setNoSigPipe(_ descriptor: Int32) {
    var enabled: Int32 = 1
    _ = withUnsafePointer(to: &enabled) {
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
    }
}

private func connectLoopback(_ descriptor: Int32, port: UInt16) -> Int32 {
    var address = makeLoopbackAddress(port: port)
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}

private func socketError(_ descriptor: Int32) -> Int32? {
    var value: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &value, &length) == 0 else {
        return nil
    }
    return value
}

private func validateInheritedListener(_ descriptor: Int32, expectedPort: UInt16) -> Bool {
    var type: Int32 = 0
    var typeLength = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &typeLength) == 0,
          type == SOCK_STREAM else {
        return false
    }

    var accepting: Int32 = 0
    var acceptingLength = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(descriptor, SOL_SOCKET, SO_ACCEPTCONN, &accepting, &acceptingLength) == 0,
          accepting != 0 else {
        return false
    }

    var address = sockaddr_in()
    var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &addressLength)
        }
    }
    guard result == 0,
          address.sin_family == sa_family_t(AF_INET),
          UInt16(bigEndian: address.sin_port) == expectedPort else {
        return false
    }

    var loopback = in_addr()
    "127.0.0.1".withCString { value in
        _ = inet_pton(AF_INET, value, &loopback)
    }
    return address.sin_addr.s_addr == loopback.s_addr
}

private func activateLaunchdListener(name: String, expectedPort: UInt16) throws -> Int32 {
    var descriptorArray: UnsafeMutablePointer<Int32>? = nil
    var count = 0
    let result = name.withCString { value in
        latteLaunchActivateSocket(value, &descriptorArray, &count)
    }
    guard result == 0 else {
        throw RelayError.system("launch_activate_socket(\(name)) failed: \(posixMessage(result))")
    }
    guard let descriptorArray else {
        throw RelayError.invalidInheritedSocket("launchd returned no descriptors for \(name)")
    }
    defer { free(descriptorArray) }

    guard count == 1 else {
        for index in 0..<max(0, count) {
            close(descriptorArray[index])
        }
        throw RelayError.invalidInheritedSocket("\(name) must contain exactly one IPv4 loopback listener")
    }
    let descriptor = descriptorArray[0]
    guard validateInheritedListener(descriptor, expectedPort: expectedPort) else {
        close(descriptor)
        throw RelayError.invalidInheritedSocket("\(name) is not an AF_INET loopback listener on port \(expectedPort)")
    }
    guard setNonBlocking(descriptor) else {
        close(descriptor)
        throw RelayError.system("could not make inherited \(name) listener non-blocking: \(posixMessage())")
    }
    return descriptor
}

private func makeTestListener(port: UInt16) throws -> Int32 {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw RelayError.system("could not create test listener: \(posixMessage())")
    }
    var address = makeLoopbackAddress(port: port)
    var reuse: Int32 = 1
    _ = withUnsafePointer(to: &reuse) {
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, Darwin.listen(descriptor, 128) == 0, setNonBlocking(descriptor) else {
        let message = posixMessage()
        close(descriptor)
        throw RelayError.system("could not bind test listener on 127.0.0.1:\(port): \(message)")
    }
    return descriptor
}

private struct ByteBuffer {
    private var storage = Data()
    private var offset = 0

    var count: Int { storage.count - offset }
    var isEmpty: Bool { count == 0 }

    mutating func append(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count > 0 else { return }
        storage.append(bytes.bindMemory(to: UInt8.self))
    }

    mutating func consume(_ amount: Int) {
        guard amount > 0 else { return }
        offset += amount
        if offset >= storage.count {
            storage.removeAll(keepingCapacity: true)
            offset = 0
        } else if offset >= 64 * 1024 {
            storage = Data(storage[offset...])
            offset = 0
        }
    }

    func withReadableBytes<R>(_ body: (UnsafeRawBufferPointer) -> R) -> R {
        storage.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress, count > 0 else {
                return body(UnsafeRawBufferPointer(start: nil, count: 0))
            }
            let readable = UnsafeRawBufferPointer(
                start: baseAddress.advanced(by: offset),
                count: count
            )
            return body(readable)
        }
    }
}

private final class RelayPipe {
    weak var connection: RelayConnection?
    let sourceDescriptor: Int32
    let targetDescriptor: Int32
    let queue: DispatchQueue
    var readSource: DispatchSourceRead?
    var pending = ByteBuffer()
    var sourceEnded = false
    var readPaused = false
    var readContinuationScheduled = false
    var writeRetryScheduled = false
    var targetWriteShutdown = false
    var stopped = false

    init(connection: RelayConnection, sourceDescriptor: Int32, targetDescriptor: Int32) {
        self.connection = connection
        self.sourceDescriptor = sourceDescriptor
        self.targetDescriptor = targetDescriptor
        self.queue = connection.queue
    }

    func start() {
        let reader = DispatchSource.makeReadSource(fileDescriptor: sourceDescriptor, queue: queue)
        reader.setEventHandler { [weak self] in self?.readReady() }
        reader.setCancelHandler {}
        readSource = reader

        reader.resume()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if readPaused {
            readPaused = false
            readSource?.resume()
        }
        readSource?.cancel()
    }

    private func readReady() {
        guard !stopped, !sourceEnded else { return }
        var chunksRead = 0
        while pending.count < maximumBufferedBytes, chunksRead < maxReadChunksPerCallback {
            var bytes = [UInt8](repeating: 0, count: readChunkSize)
            let received = bytes.withUnsafeMutableBytes { rawBuffer -> Int in
                recv(sourceDescriptor, rawBuffer.baseAddress, rawBuffer.count, 0)
            }
            if received > 0 {
                chunksRead += 1
                bytes.withUnsafeBytes { rawBuffer in
                    let partial = UnsafeRawBufferPointer(start: rawBuffer.baseAddress, count: received)
                    pending.append(partial)
                }
                connection?.activity()
                armWriter()
                continue
            }
            if received == 0 {
                finishSource()
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            }
            connection?.fail("read failed: \(posixMessage())")
            return
        }
        if pending.count >= maximumBufferedBytes, !readPaused {
            readPaused = true
            readSource?.suspend()
        } else if chunksRead >= maxReadChunksPerCallback {
            scheduleReadContinuation()
        }
    }

    private func writeReady() {
        guard !stopped else { return }
        while !pending.isEmpty {
            let sent = pending.withReadableBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return send(targetDescriptor, baseAddress, bytes.count, 0)
            }
            if sent > 0 {
                pending.consume(sent)
                connection?.activity()
                continue
            }
            if sent < 0 && (errno == EINTR) { continue }
            if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                scheduleWriteRetry()
                return
            }
            connection?.fail("write failed: \(posixMessage())")
            return
        }

        if sourceEnded {
            shutdownTargetWrite()
        }
        if readPaused && pending.count <= resumeReadingBelowBytes {
            readPaused = false
            readSource?.resume()
        }
    }

    private func finishSource() {
        guard !sourceEnded else { return }
        sourceEnded = true
        if readPaused {
            readPaused = false
            readSource?.resume()
        }
        readSource?.cancel()
        if pending.isEmpty {
            shutdownTargetWrite()
        }
    }

    private func scheduleReadContinuation() {
        guard !readContinuationScheduled, !stopped, !sourceEnded, !readPaused else { return }
        readContinuationScheduled = true
        // Dispatch sources are level-triggered, but an explicit continuation
        // also guarantees progress when a continuously readable descriptor
        // has no new readiness transition after this bounded callback.
        queue.async { [weak self] in
            guard let self else { return }
            self.readContinuationScheduled = false
            self.readReady()
        }
    }

    private func shutdownTargetWrite() {
        guard !targetWriteShutdown, !stopped else { return }
        targetWriteShutdown = true
        _ = Darwin.shutdown(targetDescriptor, SHUT_WR)
        connection?.pipeMayFinish()
    }

    private func armWriter() {
        guard !stopped else { return }
        // A socket can already be writable when the dispatch source is
        // created, so write immediately and poll only while backpressured.
        writeReady()
    }

    private func scheduleWriteRetry() {
        guard !writeRetryScheduled, !stopped else { return }
        writeRetryScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in
            guard let self else { return }
            self.writeRetryScheduled = false
            self.writeReady()
        }
    }
}

private final class RelayConnection {
    let clientDescriptor: Int32
    let destination: Destination
    let queue: DispatchQueue
    var onEnd: (() -> Void)?
    var destinationDescriptor: Int32 = -1
    var connectSource: DispatchSourceWrite?
    var connectTimer: DispatchSourceTimer?
    var idleTimer: DispatchSourceTimer?
    var lifetimeTimer: DispatchSourceTimer?
    var clientToDestination: RelayPipe?
    var destinationToClient: RelayPipe?
    var stopped = false

    init(clientDescriptor: Int32, destination: Destination) {
        self.clientDescriptor = clientDescriptor
        self.destination = destination
        self.queue = DispatchQueue(label: "dev.caramel.ports.connection", qos: .utility)
    }

    func start() {
        queue.async { [weak self] in self?.begin() }
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    func activity() {
        guard !stopped else { return }
        idleTimer?.schedule(deadline: .now() + .seconds(idleTimeoutSeconds))
    }

    func fail(_ message: String) {
        _ = message // Diagnostics stay out of the byte path and launchd logs.
        stopOnQueue()
    }

    func pipeMayFinish() {
        guard !stopped,
              let forward = clientToDestination,
              let reverse = destinationToClient,
              forward.sourceEnded, forward.pending.isEmpty, forward.targetWriteShutdown,
              reverse.sourceEnded, reverse.pending.isEmpty, reverse.targetWriteShutdown else {
            return
        }
        stopOnQueue()
    }

    private func begin() {
        guard !stopped else { return }
        setNoSigPipe(clientDescriptor)
        guard setNonBlocking(clientDescriptor) else {
            stopOnQueue()
            return
        }

        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            stopOnQueue()
            return
        }
        destinationDescriptor = descriptor
        setNoSigPipe(descriptor)
        guard setNonBlocking(descriptor) else {
            stopOnQueue()
            return
        }

        let lifetime = DispatchSource.makeTimerSource(queue: queue)
        lifetime.setEventHandler { [weak self] in self?.stopOnQueue() }
        lifetime.schedule(deadline: .now() + .seconds(maximumConnectionLifetimeSeconds))
        lifetimeTimer = lifetime
        lifetime.resume()

        let result = connectLoopback(descriptor, port: destination.port)
        if result == 0 {
            connected()
            return
        }
        guard errno == EINPROGRESS || errno == EWOULDBLOCK else {
            stopOnQueue()
            return
        }

        let connecting = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
        connecting.setEventHandler { [weak self] in self?.connectReady() }
        connecting.setCancelHandler {}
        connectSource = connecting
        connecting.resume()

        let timeout = DispatchSource.makeTimerSource(queue: queue)
        timeout.setEventHandler { [weak self] in self?.stopOnQueue() }
        timeout.schedule(deadline: .now() + .seconds(connectTimeoutSeconds))
        connectTimer = timeout
        timeout.resume()
    }

    private func connectReady() {
        guard !stopped else { return }
        guard let error = socketError(destinationDescriptor), error == 0 else {
            stopOnQueue()
            return
        }
        connected()
    }

    private func connected() {
        guard !stopped else { return }
        connectSource?.cancel()
        connectSource = nil
        connectTimer?.cancel()
        connectTimer = nil

        let idle = DispatchSource.makeTimerSource(queue: queue)
        idle.setEventHandler { [weak self] in self?.stopOnQueue() }
        idle.schedule(deadline: .now() + .seconds(idleTimeoutSeconds))
        idleTimer = idle
        idle.resume()

        let forward = RelayPipe(connection: self, sourceDescriptor: clientDescriptor, targetDescriptor: destinationDescriptor)
        let reverse = RelayPipe(connection: self, sourceDescriptor: destinationDescriptor, targetDescriptor: clientDescriptor)
        clientToDestination = forward
        destinationToClient = reverse
        forward.start()
        reverse.start()
    }

    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        clientToDestination?.stop()
        destinationToClient?.stop()
        connectSource?.cancel()
        connectTimer?.cancel()
        idleTimer?.cancel()
        lifetimeTimer?.cancel()
        close(clientDescriptor)
        if destinationDescriptor >= 0 {
            close(destinationDescriptor)
            destinationDescriptor = -1
        }
        onEnd?()
    }
}

private final class RelayListener {
    let descriptor: Int32
    let destination: Destination
    var source: DispatchSourceRead?
    var acceptContinuationScheduled = false
    var closed = false

    init(descriptor: Int32, destination: Destination) {
        self.descriptor = descriptor
        self.destination = destination
    }

    func start(queue: DispatchQueue, handler: @escaping (RelayListener) -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            handler(self)
        }
        source.setCancelHandler { [weak self] in self?.closeNow() }
        self.source = source
        source.resume()
    }

    func stop() {
        if let source {
            source.cancel()
        } else {
            closeNow()
        }
    }

    func closeNow() {
        guard !closed else { return }
        closed = true
        close(descriptor)
    }
}

private final class PortRelay {
    let configuration: RelayConfiguration
    let queue = DispatchQueue(label: "dev.caramel.ports.accept", qos: .utility)
    var listeners: [RelayListener] = []
    var connections: [ObjectIdentifier: RelayConnection] = [:]
    var activeConnections = 0
    var stopping = false
    var signalSources: [DispatchSourceSignal] = []

    init(configuration: RelayConfiguration) {
        self.configuration = configuration
    }

    func start() throws {
        do {
            if configuration.isTestMode {
                guard let httpPort = configuration.httpListenerPort,
                      let httpsPort = configuration.httpsListenerPort else {
                    throw RelayError.usage("test listener ports are incomplete")
                }
                let httpDescriptor = try makeTestListener(port: httpPort)
                listeners.append(RelayListener(descriptor: httpDescriptor, destination: configuration.httpDestination))
                let httpsDescriptor = try makeTestListener(port: httpsPort)
                listeners.append(RelayListener(descriptor: httpsDescriptor, destination: configuration.httpsDestination))
            } else {
                let httpDescriptor = try activateLaunchdListener(name: "http", expectedPort: productionHTTPPort)
                listeners.append(RelayListener(descriptor: httpDescriptor, destination: configuration.httpDestination))
                let httpsDescriptor = try activateLaunchdListener(name: "https", expectedPort: productionHTTPSPort)
                listeners.append(RelayListener(descriptor: httpsDescriptor, destination: configuration.httpsDestination))
            }
        } catch {
            listeners.forEach { $0.closeNow() }
            listeners.removeAll()
            throw error
        }

        for listener in listeners {
            listener.start(queue: queue) { [weak self] listener in
                guard let self else { return }
                self.accept(listener)
            }
        }
        installSignalHandlers()
    }

    func run() {
        dispatchMain()
    }

    private func accept(_ listener: RelayListener) {
        guard !stopping else { return }
        var acceptedCount = 0
        while !stopping, acceptedCount < maxAcceptsPerCallback {
            let client = Darwin.accept(listener.descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            acceptedCount += 1
            guard activeConnections < maxActiveConnections else {
                close(client)
                continue
            }
            guard setNonBlocking(client) else {
                close(client)
                continue
            }
            setNoSigPipe(client)
            activeConnections += 1
            let connection = RelayConnection(clientDescriptor: client, destination: listener.destination)
            let identifier = ObjectIdentifier(connection)
            connection.onEnd = { [weak self] in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.activeConnections = max(0, self.activeConnections - 1)
                    self.connections.removeValue(forKey: identifier)
                }
            }
            connections[identifier] = connection
            connection.start()
        }
        if acceptedCount == maxAcceptsPerCallback, !stopping {
            scheduleAcceptContinuation(listener)
        }
    }

    private func scheduleAcceptContinuation(_ listener: RelayListener) {
        guard !listener.acceptContinuationScheduled, !stopping else { return }
        listener.acceptContinuationScheduled = true
        // Yield after a bounded accept batch so signal handling and the other
        // listener cannot be starved by a connection churn flood.
        queue.async { [weak self, weak listener] in
            guard let self, let listener else { return }
            listener.acceptContinuationScheduled = false
            self.accept(listener)
        }
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [weak self] in self?.stopAndExit() }
            source.setCancelHandler {}
            source.resume()
            signalSources.append(source)
        }
    }

    private func stopAndExit() {
        guard !stopping else { return }
        stopping = true
        signalSources.forEach { $0.cancel() }
        listeners.forEach { $0.stop() }
        connections.values.forEach { $0.stop() }
        exit(EXIT_SUCCESS)
    }
}

@main
private struct PortRelayMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        do {
            let configuration = try RelayConfiguration.parse(arguments: CommandLine.arguments.dropFirst())
            let relay = PortRelay(configuration: configuration)
            try relay.start()
            relay.run()
        } catch {
            let message = "latte-port-relay: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }
}
