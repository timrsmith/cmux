import Darwin
import Foundation
import Testing

/// `cmux close-surface`, `cmux workspace close` / `close-workspace` and
/// `cmux close-window` forward `--force` so the app discards unsaved edits only
/// when the caller asked for it, and an `unsaved_changes` refusal exits
/// non-zero with the app's message.
@Suite(.serialized)
struct CLICloseForceFlagTests {
    private static let workspaceId = "6B6F2B7E-1D6D-4F0C-9C36-8E1D7C2A0F11"
    private static let surfaceId = "2C4E0D2A-7A1B-4C3D-8E9F-0A1B2C3D4E5F"
    private static let windowId = "0F9E8D7C-6B5A-4433-9221-100F0E0D0C0B"

    @Test func closeSurfaceForwardsForce() async throws {
        let run = try await run(
            ["close-surface", "--workspace", Self.workspaceId, "--surface", Self.surfaceId, "--force"],
            respond: Self.surfaceCloseResponder(closeResponse: { id in
                Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": Self.workspaceId,
                    "surface_id": Self.surfaceId,
                ])
            })
        )

        #expect(run.status == 0, Comment(rawValue: run.output))
        let params = try #require(run.request(for: "surface.close")?["params"] as? [String: Any])
        #expect(params["force"] as? Bool == true, Comment(rawValue: "\(params)"))
    }

    @Test func closeSurfaceWithoutForceSendsNoForce() async throws {
        let run = try await run(
            ["close-surface", "--workspace", Self.workspaceId, "--surface", Self.surfaceId],
            respond: Self.surfaceCloseResponder(closeResponse: { id in
                Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": Self.workspaceId,
                    "surface_id": Self.surfaceId,
                ])
            })
        )

        #expect(run.status == 0, Comment(rawValue: run.output))
        let params = try #require(run.request(for: "surface.close")?["params"] as? [String: Any])
        #expect(params["force"] == nil, Comment(rawValue: "\(params)"))
    }

    @Test func workspaceCloseForwardsForce() async throws {
        let run = try await run(
            ["workspace", "close", Self.workspaceId, "--force"],
            respond: { method, id in
                guard method == "workspace.close" else { return nil }
                return Self.v2Response(id: id, ok: true, result: ["workspace_id": Self.workspaceId])
            }
        )

        #expect(run.status == 0, Comment(rawValue: run.output))
        let params = try #require(run.request(for: "workspace.close")?["params"] as? [String: Any])
        #expect(params["force"] as? Bool == true, Comment(rawValue: "\(params)"))
    }

    @Test func legacyCloseWorkspaceForwardsForce() async throws {
        let run = try await run(
            ["close-workspace", "--workspace", Self.workspaceId, "--force"],
            respond: { method, id in
                guard method == "workspace.close" else { return nil }
                return Self.v2Response(id: id, ok: true, result: ["workspace_id": Self.workspaceId])
            }
        )

        #expect(run.status == 0, Comment(rawValue: run.output))
        let params = try #require(run.request(for: "workspace.close")?["params"] as? [String: Any])
        #expect(params["force"] as? Bool == true, Comment(rawValue: "\(params)"))
    }

    @Test func closeWindowForwardsForceOnTheLegacyLine() async throws {
        let run = try await run(
            ["close-window", "--window", Self.windowId, "--force"],
            respondV1: { line in
                line.hasPrefix("close_window ") ? "OK" : nil
            }
        )

        #expect(run.status == 0, Comment(rawValue: run.output))
        #expect(run.lines.contains("close_window \(Self.windowId) force"), Comment(rawValue: run.lines.joined(separator: "\n")))
    }

    @Test func unsavedChangesRefusalPrintsTheMessageAndExitsNonZero() async throws {
        let message = "“notes.md” has unsaved changes; save it first or pass --force."
        let run = try await run(
            ["close-surface", "--workspace", Self.workspaceId, "--surface", Self.surfaceId],
            respond: Self.surfaceCloseResponder(closeResponse: { id in
                Self.v2Response(id: id, ok: false, error: [
                    "code": "unsaved_changes",
                    "message": message,
                    "data": ["files": ["notes.md"], "surface_id": Self.surfaceId],
                ])
            })
        )

        #expect(run.status != 0, Comment(rawValue: run.output))
        #expect(run.output.contains(message), Comment(rawValue: run.output))
    }

    // MARK: - Harness

    private struct Run {
        let status: Int32
        let output: String
        let lines: [String]

        func request(for method: String) -> [String: Any]? {
            lines.compactMap { line -> [String: Any]? in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return object
            }.first { $0["method"] as? String == method }
        }
    }

    /// Drives the bundled CLI against a mock socket. `respond` answers v2
    /// requests by method (returning `nil` falls back to a `not_found` error)
    /// and `respondV1` answers plain lines; every line received is recorded.
    private func run(
        _ arguments: [String],
        respond: (@Sendable (String, String) -> String?)? = nil,
        respondV1: (@Sendable (String) -> String?)? = nil
    ) async throws -> Run {
        let socketPath = Self.socketPath()
        let server = try CloseForceMockServer(socketPath: socketPath, respond: respond, respondV1: respondV1)
        let linesTask = server.start()

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "2"

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(
            fileURLWithPath: try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self)
        )
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { completedProcess in
                continuation.resume(returning: completedProcess.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        let output = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        server.stop()
        let lines = await linesTask.value
        return Run(status: status, output: output, lines: lines)
    }

    /// `close-surface` lists the workspace's surfaces to resolve the explicit
    /// handle before closing; answer that listing with the target surface.
    private static func surfaceCloseResponder(
        closeResponse: @escaping @Sendable (String) -> String
    ) -> @Sendable (String, String) -> String? {
        { method, id in
            switch method {
            case "surface.list":
                return Self.v2Response(id: id, ok: true, result: [
                    "surfaces": [["id": Self.surfaceId, "ref": "surface:1", "index": 0]],
                ])
            case "surface.close":
                return closeResponse(id)
            default:
                return nil
            }
        }
    }

    private static func v2Response(
        id: String,
        ok: Bool,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }

    private static func socketPath() -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-close-force-\(suffix).sock")
            .path
    }

    private final class BundleToken {}
}

/// A one-connection-at-a-time mock cmux socket that records every request
/// line and answers from the supplied closures until stopped.
private final class CloseForceMockServer: @unchecked Sendable {
    private let socketPath: String
    private let listenerFD: Int32
    private let respond: (@Sendable (String, String) -> String?)?
    private let respondV1: (@Sendable (String) -> String?)?
    private let lock = NSLock()
    private var lines: [String] = []
    private var stopped = false

    init(
        socketPath: String,
        respond: (@Sendable (String, String) -> String?)?,
        respondV1: (@Sendable (String) -> String?)?
    ) throws {
        self.socketPath = socketPath
        self.respond = respond
        self.respondV1 = respondV1
        unlink(socketPath)
        listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else { throw MockServerError.socket(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw MockServerError.pathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = UInt8(bitPattern: byte)
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(listenerFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw MockServerError.bind(errno) }
        guard listen(listenerFD, 8) == 0 else { throw MockServerError.listen(errno) }
    }

    func start() -> Task<[String], Never> {
        Task.detached(priority: .userInitiated) { [self] in
            while true {
                var clientAddress = sockaddr()
                var clientLength = socklen_t(MemoryLayout<sockaddr>.size)
                let clientFD = accept(listenerFD, &clientAddress, &clientLength)
                if clientFD < 0 {
                    lock.lock()
                    let done = stopped
                    lock.unlock()
                    if done || errno != EINTR { break }
                    continue
                }
                serve(clientFD)
                Darwin.close(clientFD)
            }
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        shutdown(listenerFD, SHUT_RDWR)
        Darwin.close(listenerFD)
        unlink(socketPath)
    }

    private func serve(_ clientFD: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var pending = Data()
        while true {
            let count = read(clientFD, &buffer, buffer.count)
            guard count > 0 else { return }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                let line = String(decoding: lineData, as: UTF8.self)
                lock.lock()
                lines.append(line)
                lock.unlock()
                let response = answer(line) + "\n"
                _ = response.withCString { pointer in
                    write(clientFD, pointer, strlen(pointer))
                }
            }
        }
    }

    private func answer(_ line: String) -> String {
        if line.hasPrefix("{"),
           let data = line.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let id = (object["id"] as? String) ?? ""
            let method = (object["method"] as? String) ?? ""
            if let answer = respond?(method, id) { return answer }
            let payload: [String: Any] = [
                "id": id,
                "ok": false,
                "error": ["code": "not_found", "message": "unexpected method \(method)"],
            ]
            let data = try! JSONSerialization.data(withJSONObject: payload)
            return String(decoding: data, as: UTF8.self)
        }
        return respondV1?(line) ?? "ERROR: unexpected line"
    }

    enum MockServerError: Error {
        case socket(Int32)
        case bind(Int32)
        case listen(Int32)
        case pathTooLong
    }
}
