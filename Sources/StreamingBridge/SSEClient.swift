import Foundation
import Observation
import os
#if os(iOS)
import UIKit
#endif

/// Server-Sent Events client for streaming Claude Code chat responses.
///
/// Manages the HTTP connection lifecycle, SSE event parsing, heartbeat monitoring,
/// and automatic reconnection with exponential backoff.
///
/// ## Architecture
///
/// The SSE client uses a two-tier timeout strategy:
/// - **Initial timeout** (default 30s): Detects stuck connections before first byte
/// - **Heartbeat watchdog** (default 45s): Detects stale connections mid-stream
///
/// A `LastActivityTracker` monitors the stream using `OSAllocatedUnfairLock`
/// for thread-safe timestamp tracking without actor-hop overhead on the hot path.
///
/// ## Usage
///
/// ```swift
/// let client = SSEClient(configuration: .default)
/// client.startStream(request: ChatStreamRequest(prompt: "Hello"))
///
/// // Observe messages via @Observable
/// for message in client.messages {
///     // Process stream messages
/// }
/// ```
///
/// ## The Text Duplication Bug (P2)
///
/// A critical lesson from production: the `+=` vs `=` distinction matters
/// for assistant messages. Each `assistant` event contains the **accumulated**
/// text, not just the new token. Using `+=` on an already-accumulated string
/// produces exact duplication. The fix: use `=` (assignment) for assistant
/// events, `+=` only for `textDelta` stream events.
@MainActor
@Observable
public class SSEClient {
    /// Decoded stream messages received during the current session.
    public var messages: [StreamMessage] = []

    /// Whether the client is actively streaming.
    public var isStreaming: Bool = false

    /// Current error, if any.
    public var error: Error?

    /// Current connection state.
    public var connectionState: ConnectionState = .disconnected

    /// Connection state machine.
    public enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
    }

    // MARK: - Private Properties

    @ObservationIgnored private var streamTask: Task<Void, Never>?
    private let configuration: BridgeConfiguration
    private var currentRequest: ChatStreamRequest?
    private var reconnectAttempts = 0
    private let session: URLSession
    private var lastEventId: String?
    private var backoffSleepTask: Task<Void, Never>?

    #if os(iOS)
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?
    #endif

    nonisolated private let jsonEncoder = JSONEncoder()
    nonisolated private let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Initialization

    /// Create a new SSE client with the given configuration.
    ///
    /// - Parameter configuration: Bridge configuration controlling timeouts,
    ///   reconnection behavior, and network access. Defaults to `.default`.
    public init(configuration: BridgeConfiguration = .default) {
        self.configuration = configuration

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = configuration.totalTimeout
        config.timeoutIntervalForResource = 3600
        config.allowsExpensiveNetworkAccess = configuration.allowsExpensiveNetworkAccess
        config.allowsConstrainedNetworkAccess = configuration.allowsConstrainedNetworkAccess
        self.session = URLSession(configuration: config)

        // Cancel active SSE stream on background to save battery radio
        #if os(iOS)
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isStreaming else { return }
                self.cancel()
            }
        }
        #endif
    }

    deinit {
        streamTask?.cancel()
        #if os(iOS)
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    /// Tear down session and cancel in-flight tasks.
    /// Call from view's onDisappear for complete cleanup.
    public func cleanup() {
        #if os(iOS)
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
            backgroundObserver = nil
        }
        #endif
        cancel()
        session.invalidateAndCancel()
    }

    // MARK: - Public API

    /// Start streaming a chat request.
    ///
    /// Cancels any existing stream before starting a new one.
    /// Messages are accumulated in the `messages` array and can be
    /// observed via Swift's `@Observable` mechanism.
    ///
    /// - Parameter request: The chat stream request containing the prompt and options.
    public func startStream(request: ChatStreamRequest) {
        if isStreaming {
            cancel()
        }

        isStreaming = true
        messages = []
        error = nil
        currentRequest = request
        reconnectAttempts = 0
        connectionState = .connecting

        streamTask = Task { [weak self] in
            await self?.performStream(request: request)
        }
    }

    /// Cancel the current stream.
    public func cancel() {
        backoffSleepTask?.cancel()
        backoffSleepTask = nil
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        connectionState = .disconnected
        currentRequest = nil
        reconnectAttempts = 0
        lastEventId = nil
    }

    /// Trigger an immediate reconnection for the current request.
    /// Cancels any active backoff sleep.
    public func resetAndReconnect() {
        backoffSleepTask?.cancel()
        backoffSleepTask = nil

        guard let request = currentRequest else { return }

        if !isStreaming {
            reconnectAttempts = 0
            isStreaming = true
            error = nil
            connectionState = .connecting
            streamTask = Task { [weak self] in
                await self?.performStream(request: request)
            }
        }
    }

    // MARK: - Stream Implementation

    private func performStream(request: ChatStreamRequest) async {
        guard let url = URL(string: "\(configuration.backendURL)\(configuration.streamEndpoint)") else {
            self.error = URLError(.badURL)
            self.isStreaming = false
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.addValue("text/event-stream", forHTTPHeaderField: "Accept")

        if let lastEventId {
            urlRequest.addValue(lastEventId, forHTTPHeaderField: "Last-Event-ID")
        }

        do {
            urlRequest.httpBody = try jsonEncoder.encode(request)
        } catch {
            self.error = error
            self.isStreaming = false
            return
        }

        do {
            // Race connection against 60s timeout
            let urlSession = self.session
            let (asyncBytes, response) = try await withThrowingTaskGroup(
                of: (URLSession.AsyncBytes, URLResponse).self
            ) { group in
                group.addTask {
                    try await urlSession.bytes(for: urlRequest)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    throw URLError(.timedOut)
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }

            connectionState = .connected
            reconnectAttempts = 0

            // Heartbeat watchdog: detect stale connections
            let lastActivity = LastActivityTracker()
            let watchdogTimeout = configuration.heartbeatTimeout

            let heartbeatWatchdog = Task.detached { [watchdogTimeout] in
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    if lastActivity.secondsSinceLastActivity() > watchdogTimeout {
                        throw URLError(.timedOut)
                    }
                }
            }
            defer { heartbeatWatchdog.cancel() }

            // Parse SSE event stream
            var currentEvent = ""
            var currentData = ""

            for try await line in asyncBytes.lines {
                lastActivity.touch()

                if line.hasPrefix("event:") {
                    currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("id:") {
                    lastEventId = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    currentData = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)

                    if !currentData.isEmpty {
                        await parseAndAddMessage(event: currentEvent, data: currentData)
                    }

                    currentEvent = ""
                    currentData = ""
                } else if line.hasPrefix(":") {
                    // Heartbeat/ping comment — activity already tracked
                    continue
                }
            }

            connectionState = .disconnected
        } catch is CancellationError {
            connectionState = .disconnected
        } catch {
            if await shouldReconnect(error: error) {
                return
            }
            self.error = error
            connectionState = .disconnected
        }

        isStreaming = false
    }

    // MARK: - Reconnection

    private func shouldReconnect(error: Error) async -> Bool {
        guard let request = currentRequest,
              reconnectAttempts < configuration.maxReconnectAttempts,
              isNetworkError(error) else {
            return false
        }

        reconnectAttempts += 1
        connectionState = .reconnecting(attempt: reconnectAttempts)

        // Exponential backoff capped at 30 seconds
        let baseNanos = UInt64(configuration.reconnectBaseDelay * 1_000_000_000)
        let delay = min(baseNanos * UInt64(1 << (reconnectAttempts - 1)), 30_000_000_000)

        let sleepTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: delay)
        }
        backoffSleepTask = sleepTask
        await sleepTask.value
        backoffSleepTask = nil

        if Task.isCancelled { return false }

        await performStream(request: request)
        return true
    }

    private func isNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let networkErrorCodes: [Int] = [
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed,
        ]
        return nsError.domain == NSURLErrorDomain && networkErrorCodes.contains(nsError.code)
    }

    // MARK: - Message Parsing

    private func parseAndAddMessage(event: String, data: String) async {
        if event == "done" { return }

        guard let jsonData = data.data(using: .utf8) else { return }

        do {
            let message = try jsonDecoder.decode(StreamMessage.self, from: jsonData)
            messages.append(message)
        } catch {
            // Log decoding errors but don't fail the stream
            #if DEBUG
            print("[SSEClient] Decode error: \(error) — data: \(data.prefix(200))")
            #endif
        }
    }
}

// MARK: - LastActivityTracker

/// Thread-safe tracker for last SSE activity timestamp.
///
/// Uses `OSAllocatedUnfairLock` instead of an actor to avoid actor-hop
/// overhead on every received SSE line (hot path during streaming).
private final class LastActivityTracker: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: Date())

    func touch() {
        storage.withLock { $0 = Date() }
    }

    func secondsSinceLastActivity() -> TimeInterval {
        let last = storage.withLock { $0 }
        return Date().timeIntervalSince(last)
    }
}
