import Foundation

/// Configuration for the StreamingBridge.
///
/// Controls backend URL, timeouts, reconnection behavior, and Python bridge settings.
///
/// ## Usage
///
/// ```swift
/// let config = BridgeConfiguration(
///     backendURL: "http://localhost:9999",
///     initialTimeout: 30,
///     totalTimeout: 300
/// )
/// let client = SSEClient(configuration: config)
/// ```
public struct BridgeConfiguration: Sendable {
    /// Base URL of the Vapor backend (e.g., "http://localhost:9999").
    public let backendURL: String

    /// Timeout in seconds for the initial connection to receive first byte.
    /// Default: 30 seconds. If Claude needs time to think before responding,
    /// this should be generous enough to avoid premature disconnection.
    public let initialTimeout: TimeInterval

    /// Total timeout in seconds for the entire streaming session.
    /// Default: 300 seconds (5 minutes). Long conversations or complex
    /// prompts may require extending this.
    public let totalTimeout: TimeInterval

    /// Heartbeat watchdog timeout in seconds. If no data arrives within
    /// this interval, the connection is declared stale.
    /// Default: 45 seconds.
    public let heartbeatTimeout: TimeInterval

    /// Maximum number of automatic reconnection attempts on network errors.
    /// Default: 10. Uses exponential backoff capped at 30 seconds.
    public let maxReconnectAttempts: Int

    /// Base delay for reconnection backoff in seconds.
    /// Actual delay = min(baseDelay * 2^(attempt-1), 30).
    /// Default: 2 seconds.
    public let reconnectBaseDelay: TimeInterval

    /// Whether to allow expensive network access (e.g., hotspot).
    /// Default: true.
    public let allowsExpensiveNetworkAccess: Bool

    /// Whether to allow constrained network access (e.g., Low Data Mode).
    /// Default: false. SSE streaming should not consume metered data.
    public let allowsConstrainedNetworkAccess: Bool

    /// API path for the chat streaming endpoint.
    /// Default: "/api/v1/chat/stream".
    public let streamEndpoint: String

    /// Path to the Python SDK wrapper script, relative to project root.
    /// Default: "scripts/sdk-wrapper.py".
    public let sdkWrapperPath: String

    /// Default configuration suitable for local development.
    public static let `default` = BridgeConfiguration()

    public init(
        backendURL: String = "http://localhost:9999",
        initialTimeout: TimeInterval = 30,
        totalTimeout: TimeInterval = 300,
        heartbeatTimeout: TimeInterval = 45,
        maxReconnectAttempts: Int = 10,
        reconnectBaseDelay: TimeInterval = 2,
        allowsExpensiveNetworkAccess: Bool = true,
        allowsConstrainedNetworkAccess: Bool = false,
        streamEndpoint: String = "/api/v1/chat/stream",
        sdkWrapperPath: String = "scripts/sdk-wrapper.py"
    ) {
        self.backendURL = backendURL
        self.initialTimeout = initialTimeout
        self.totalTimeout = totalTimeout
        self.heartbeatTimeout = heartbeatTimeout
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectBaseDelay = reconnectBaseDelay
        self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        self.streamEndpoint = streamEndpoint
        self.sdkWrapperPath = sdkWrapperPath
    }
}
