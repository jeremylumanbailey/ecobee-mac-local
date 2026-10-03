import Foundation

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Serial JSON RPC over anonymous pipes. No network listener and no secrets in argv or files.
@MainActor final class HelperConnection: HelperRequesting {
    private let executableURL: URL?
    private let arguments: [String]
    private let requestTimeout: Duration
    var hasPendingRequest: Bool { pending != nil }
    init(executableURL: URL? = nil, arguments: [String] = [], requestTimeout: Duration = .seconds(48)) {
        self.executableURL = executableURL; self.arguments = arguments; self.requestTimeout = requestTimeout
    }
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var pending: (String, CheckedContinuation<[String: Any], Error>)?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()

    func start() throws {
        if process?.isRunning == true { return }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/HAPHelper/HAPHelper")
        let task = Process()
        if let executableURL {
            task.executableURL = executableURL; task.arguments = arguments
        } else if FileManager.default.isExecutableFile(atPath: bundled.path) {
            task.executableURL = bundled
        } else if let executable = ProcessInfo.processInfo.environment["ECOBEE_HELPER_PYTHON"],
                  let script = ProcessInfo.processInfo.environment["ECOBEE_HELPER_SCRIPT"] {
            task.executableURL = URL(fileURLWithPath: executable)
            task.arguments = ["-u", script]
        } else { throw AppFailure("The local connection helper is missing. Run scripts/build-app.sh to assemble the application.") }
        let toHelper = Pipe(), fromHelper = Pipe()
        task.standardInput = toHelper
        task.standardOutput = fromHelper
        task.standardError = FileHandle.nullDevice // Never retain potentially sensitive library diagnostics.
        input = toHelper.fileHandleForWriting
        output = fromHelper.fileHandleForReading
        buffer.removeAll()
        let generation = UUID()
        self.generation = generation
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard self?.generation == generation else { return }
                self?.receive(data)
            }
        }
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.generation == generation else { return }
                self?.failed("The local connection stopped. Reconnect to try again.")
            }
        }
        process = task
        do { try task.run() } catch { stop(); throw error }
    }
    func request(_ command: String, _ fields: [String: Any] = [:]) async throws -> [String: Any] {
        guard pending == nil else { throw AppFailure("Another thermostat request is still running.") }
        try start()
        let id = UUID().uuidString
        var message = fields
        message["id"] = id; message["command"] = command
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        return try await withCheckedThrowingContinuation { continuation in
            pending = (id, continuation)
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: self?.requestTimeout ?? .seconds(48)) } catch { return }
                self?.failed("The thermostat request timed out. If you changed a setting, reconnect and check it before trying again.")
                self?.stop()
            }
            do { try input?.write(contentsOf: data) }
            catch { failed("Could not contact the local helper. Reconnect to try again."); stop() }
        }
    }
    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        if buffer.count > 4_000_000 { failed("The local helper returned an oversized response."); stop(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let response = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = response["id"] as? String, let current = pending, current.0 == id else { continue }
            pending = nil; timeout?.cancel(); timeout = nil
            if response["ok"] as? Bool == true, let result = response["result"] as? [String: Any] { current.1.resume(returning: result) }
            else { current.1.resume(throwing: AppFailure(response["error"] as? String ?? "Local communication failed.")) }
        }
    }
    private func failed(_ message: String) {
        timeout?.cancel(); timeout = nil
        let current = pending; pending = nil
        current?.1.resume(throwing: AppFailure(message))
    }
    func stop() {
        generation = UUID()
        output?.readabilityHandler = nil
        process?.terminationHandler = nil
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil; input = nil; output = nil
        failed("The local connection was closed.")
    }
}
