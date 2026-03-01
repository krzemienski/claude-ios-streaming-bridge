import Foundation
import os

/// Service for spawning Claude CLI/SDK processes with streaming JSON output.
///
/// ## Architecture
///
/// Supports two execution backends:
/// 1. **Agent SDK** (default): Spawns `python3 sdk-wrapper.py` which calls the
///    `claude-agent-sdk` Python package. The SDK wraps Claude CLI, inherits
///    OAuth auth, and avoids nesting detection issues.
/// 2. **CLI fallback**: Spawns `claude -p --output-format stream-json` directly.
///    Use when running outside an active Claude Code session.
///
/// ## Critical: Environment Variable Stripping
///
/// Claude CLI includes nesting detection. If `CLAUDECODE=1` or any `CLAUDE_CODE_*`
/// env vars are present, the CLI refuses to execute. When your backend runs inside
/// a Claude Code development session, the subprocess inherits these variables.
///
/// **The fix is three lines of code. Finding those three lines cost a full session.**
///
/// ```swift
/// var env = ProcessInfo.processInfo.environment
/// env.removeValue(forKey: "CLAUDECODE")
/// env = env.filter { !$0.key.hasPrefix("CLAUDE_CODE_") }
/// process.environment = env
/// ```
///
/// ## Two-Tier Timeout Protection
///
/// - 30s initial timeout: Triggers if no stdout data received (detects stuck CLI)
/// - 5min total timeout: Kills long-running processes (prevents runaway execution)
///
/// ## NSTask terminationStatus Crash
///
/// **Always call `process.waitUntilExit()` before accessing `process.terminationStatus`.**
/// Reading EOF from stdout does NOT mean the process has exited. There is a race
/// between the pipe closing and the process terminating. Accessing `terminationStatus`
/// on a still-running Process throws `NSInvalidArgumentException`.
public actor ClaudeExecutorService {
    private let configuration: BridgeConfiguration
    private var activeProcesses: [String: Process] = [:]
    private let readQueue = DispatchQueue(label: "streaming-bridge.stdout-reader", qos: .userInitiated)

    /// Thread-safe boolean for sharing timeout state across GCD queues.
    private final class AtomicBool: @unchecked Sendable {
        private var _value: Bool
        private let lock = NSLock()
        init(_ value: Bool) { _value = value }
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); defer { lock.unlock() }; _value = newValue }
        }
    }

    public init(configuration: BridgeConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Check if Claude CLI is available in PATH.
    public func isAvailable() async -> Bool {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "which claude"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            defer { pipe.fileHandleForReading.closeFile() }
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Execute a Claude query with streaming JSON output.
    ///
    /// - Parameters:
    ///   - prompt: User prompt text
    ///   - workingDirectory: Optional working directory for project context
    ///   - model: Optional model override (e.g., "sonnet", "opus")
    ///   - sessionId: Optional session ID for continuation
    /// - Returns: AsyncThrowingStream yielding StreamMessage events
    nonisolated public func execute(
        prompt: String,
        workingDirectory: String? = nil,
        model: String? = nil,
        sessionId: String? = nil
    ) -> AsyncThrowingStream<StreamMessage, Error> {
        return executeWithSDK(
            prompt: prompt,
            workingDirectory: workingDirectory,
            model: model,
            sessionId: sessionId
        )
    }

    /// Cancel an active session's process.
    public func cancel(sessionId: String) async {
        if let process = activeProcesses[sessionId], process.isRunning {
            process.terminate()
        }
        activeProcesses.removeValue(forKey: sessionId)
    }

    // MARK: - SDK Execution

    private nonisolated func executeWithSDK(
        prompt: String,
        workingDirectory: String?,
        model: String?,
        sessionId: String?
    ) -> AsyncThrowingStream<StreamMessage, Error> {
        let config = self.configuration

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(100)) { continuation in
            // Build SDK config JSON
            let sdkConfig = Self.buildSDKConfig(
                prompt: prompt,
                model: model,
                sessionId: sessionId,
                workingDirectory: workingDirectory
            )

            let projectRoot = workingDirectory ?? FileManager.default.currentDirectoryPath
            let wrapperPath = "\(projectRoot)/\(config.sdkWrapperPath)"
            let command = "python3 \(Self.shellEscape(wrapperPath)) \(Self.shellEscape(sdkConfig))"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")

            // CRITICAL: Strip CLAUDE* env vars to prevent nesting detection.
            // Without this, Claude CLI silently refuses to execute inside
            // an active Claude Code session — no error, no stderr, just
            // a zero-byte response.
            let cleanCmd = "for v in $(env | grep ^CLAUDE | cut -d= -f1); do unset $v; done; \(command)"
            process.arguments = ["-l", "-c", cleanCmd]

            if let dir = workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: dir)
            }

            // Belt-and-suspenders: also strip from Process.environment
            var env = ProcessInfo.processInfo.environment
            for key in env.keys where key.hasPrefix("CLAUDE") {
                env.removeValue(forKey: key)
            }
            process.environment = env

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            stdinPipe.fileHandleForWriting.closeFile()

            let resolvedSessionId = sessionId ?? UUID().uuidString
            Task { [weak self] in
                await self?.storeProcess(resolvedSessionId, process: process)
            }

            do {
                try process.run()
            } catch {
                outputPipe.fileHandleForReading.closeFile()
                errorPipe.fileHandleForReading.closeFile()
                continuation.yield(.error(StreamError(
                    code: "LAUNCH_ERROR",
                    message: "Failed to launch SDK wrapper: \(error.localizedDescription)"
                )))
                continuation.finish()
                return
            }

            // Two-tier timeout mechanism
            let didTimeout = AtomicBool(false)

            let timeoutWork = DispatchWorkItem {
                didTimeout.value = true
                process.terminate()
                outputPipe.fileHandleForReading.closeFile()
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + config.initialTimeout,
                execute: timeoutWork
            )

            let totalTimeoutWork = DispatchWorkItem {
                if process.isRunning {
                    didTimeout.value = true
                    process.terminate()
                    outputPipe.fileHandleForReading.closeFile()
                }
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + config.totalTimeout,
                execute: totalTimeoutWork
            )

            // Read stdout on dedicated queue (no RunLoop dependency)
            self.readQueue.async {
                Self.readStdout(
                    pipe: outputPipe,
                    errorPipe: errorPipe,
                    process: process,
                    sessionId: resolvedSessionId,
                    didTimeout: didTimeout,
                    timeoutWork: timeoutWork,
                    totalTimeoutWork: totalTimeoutWork,
                    continuation: continuation,
                    executor: self
                )
            }
        }
    }

    // MARK: - Shared Stdout Reader

    /// Read NDJSON lines from process stdout and yield StreamMessages.
    ///
    /// This runs on a dedicated GCD queue to avoid any RunLoop dependency.
    /// Each JSON line is decoded independently — a malformed line is logged
    /// but doesn't kill the stream.
    private nonisolated static func readStdout(
        pipe: Pipe,
        errorPipe: Pipe,
        process: Process,
        sessionId: String,
        didTimeout: AtomicBool,
        timeoutWork: DispatchWorkItem,
        totalTimeoutWork: DispatchWorkItem,
        continuation: AsyncThrowingStream<StreamMessage, Error>.Continuation,
        executor: ClaudeExecutorService
    ) {
        defer {
            pipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
        }

        let handle = pipe.fileHandleForReading
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var buffer = Data()

        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }

            // Cancel the initial timeout on first data received
            timeoutWork.cancel()
            buffer.append(chunk)

            guard let bufferString = String(data: buffer, encoding: .utf8) else {
                continue
            }

            let lines = bufferString.components(separatedBy: "\n")
            if lines.count > 1 {
                for i in 0..<(lines.count - 1) {
                    let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty {
                        processJsonLine(line, decoder: decoder, continuation: continuation)
                    }
                }
                let lastLine = lines[lines.count - 1]
                buffer = lastLine.data(using: .utf8) ?? Data()
            }
        }

        // Process any remaining buffer
        if let remaining = String(data: buffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !remaining.isEmpty {
            processJsonLine(remaining, decoder: decoder, continuation: continuation)
        }

        // CRITICAL: Always call waitUntilExit() before terminationStatus.
        // Reading EOF from stdout does NOT mean the process has exited.
        // Accessing terminationStatus on a running Process throws
        // NSInvalidArgumentException.
        process.waitUntilExit()
        timeoutWork.cancel()
        totalTimeoutWork.cancel()

        let exitCode = process.terminationStatus
        if exitCode != 0 {
            if didTimeout.value {
                continuation.yield(.error(StreamError(
                    code: "TIMEOUT",
                    message: "Claude timed out — the AI service may be busy. Please try again."
                )))
            } else {
                let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !errText.isEmpty {
                    continuation.yield(.error(StreamError(
                        code: "PROCESS_ERROR",
                        message: "Process exited with code \(exitCode): \(String(errText.prefix(200)))"
                    )))
                }
            }
        }

        continuation.finish()

        Task {
            await executor.removeProcess(sessionId)
        }
    }

    private static func processJsonLine(
        _ line: String,
        decoder: JSONDecoder,
        continuation: AsyncThrowingStream<StreamMessage, Error>.Continuation
    ) {
        guard let data = line.data(using: .utf8) else { return }
        do {
            let message = try decoder.decode(StreamMessage.self, from: data)
            continuation.yield(message)
        } catch {
            #if DEBUG
            print("[ClaudeExecutor] Failed to decode: \(error) — line: \(line.prefix(200))")
            #endif
        }
    }

    // MARK: - Process Management

    private func storeProcess(_ sessionId: String, process: Process) {
        activeProcesses[sessionId] = process
    }

    private func removeProcess(_ sessionId: String) {
        activeProcesses.removeValue(forKey: sessionId)
    }

    // MARK: - SDK Config Building

    private static func buildSDKConfig(
        prompt: String,
        model: String?,
        sessionId: String?,
        workingDirectory: String?
    ) -> String {
        var options: [String: Any] = [:]
        if let model { options["model"] = model }
        if let sessionId { options["session_id"] = sessionId }
        if let cwd = workingDirectory { options["cwd"] = cwd }
        options["include_partial_messages"] = true

        let config: [String: Any] = [
            "prompt": prompt,
            "options": options,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: config),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return "{\"prompt\": \"\(prompt.prefix(100))\"}"
        }
        return jsonString
    }

    /// Shell-escape a string by wrapping in single quotes.
    private static func shellEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
