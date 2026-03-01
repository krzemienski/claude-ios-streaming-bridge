import Foundation
import Observation
import StreamingBridge

/// View model for the example chat interface.
///
/// Manages chat messages, SSE streaming state, and real-time message updates
/// using the StreamingBridge package.
///
/// ## Key Design Decisions
///
/// ### Text Accumulation: `=` vs `+=`
///
/// The most insidious streaming bug is text duplication. Each `assistant`
/// event contains the **accumulated** text so far, not just the new token.
/// Using `+=` on already-accumulated text produces exact duplication.
///
/// ```swift
/// // BUG: "Hello" becomes "HelloHello"
/// message.text += textBlock.text
///
/// // FIX: assignment — the assistant event is authoritative
/// message.text = textBlock.text
/// ```
///
/// For `textDelta` stream events, `+=` is correct because each delta
/// contains only the new characters since the last delta.
///
/// ### Message Index High-Water Mark
///
/// When the stream ends, preserve the current message count instead of
/// resetting `lastProcessedMessageIndex` to 0. Resetting causes the
/// message processing loop to replay every message from the beginning,
/// duplicating the entire conversation.
@Observable
@MainActor
class ChatViewModel {
    /// Messages in the conversation.
    var messages: [ChatMessage] = []

    /// Whether Claude is currently streaming a response.
    var isStreaming = false

    /// Current error, if any.
    var error: Error?

    /// Connection state for display.
    var connectionState: SSEClient.ConnectionState = .disconnected

    /// Whether connection is taking longer than expected.
    var connectingTooLong = false

    /// Approximate token count for the current stream.
    var streamTokenCount: Int = 0

    /// Elapsed time for the current stream.
    var streamElapsedSeconds: Double = 0

    /// Human-readable status text.
    var statusText: String? {
        switch connectionState {
        case .disconnected:
            return nil
        case .connecting:
            return connectingTooLong ? "Taking longer than expected..." : "Connecting..."
        case .connected:
            return isStreaming ? "Claude is responding..." : nil
        case .reconnecting(let attempt):
            return "Reconnecting (attempt \(attempt))..."
        }
    }

    private var sseClient: SSEClient?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var connectingTimer: Task<Void, Never>?
    private var lastProcessedMessageIndex = 0
    private var streamStartTime: Date?

    init() {
        let config = BridgeConfiguration.default
        let client = SSEClient(configuration: config)
        self.sseClient = client
        setupBindings(client: client)
    }

    deinit {
        observationTask?.cancel()
        connectingTimer?.cancel()
    }

    /// Send a message to Claude and start streaming the response.
    func sendMessage(_ text: String) {
        guard let sseClient else { return }

        // Add user message to the conversation
        messages.append(ChatMessage(isUser: true, text: text))

        let request = ChatStreamRequest(prompt: text)
        sseClient.startStream(request: request)
    }

    /// Cancel the current stream.
    func cancelStream() {
        sseClient?.cancel()
    }

    // MARK: - Observation Bindings

    private func setupBindings(client: SSEClient) {
        observationTask = Task { @MainActor [weak self] in
            var lastStreaming = client.isStreaming
            var lastMessageCount = 0

            while let self, !Task.isCancelled {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = client.isStreaming
                        _ = client.error
                        _ = client.connectionState
                        _ = client.messages
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { break }

                // Sync streaming state
                let streaming = client.isStreaming
                if streaming != lastStreaming {
                    self.isStreaming = streaming
                    if streaming {
                        self.streamTokenCount = 0
                        self.streamElapsedSeconds = 0
                        self.streamStartTime = Date()
                        self.lastProcessedMessageIndex = 0
                        lastMessageCount = 0
                    } else {
                        // CRITICAL: Preserve the high-water mark to prevent replay
                        let finalCount = client.messages.count
                        self.lastProcessedMessageIndex = finalCount
                        self.streamStartTime = nil
                        lastMessageCount = finalCount
                    }
                    lastStreaming = streaming
                }

                // Sync error
                self.error = client.error

                // Sync connection state
                let state = client.connectionState
                self.connectionState = state
                if case .connecting = state {
                    self.startConnectingTimer()
                } else {
                    self.connectingTimer?.cancel()
                    self.connectingTooLong = false
                }

                // Process new messages
                let msgs = client.messages
                if msgs.count > lastMessageCount {
                    let newMessages = Array(msgs.suffix(from: self.lastProcessedMessageIndex))
                    for streamMessage in newMessages {
                        self.processStreamMessage(streamMessage)
                    }
                    self.lastProcessedMessageIndex = msgs.count
                    lastMessageCount = msgs.count
                }

                // Update streaming stats
                if let startTime = self.streamStartTime {
                    self.streamElapsedSeconds = Date().timeIntervalSince(startTime)
                }
            }
        }
    }

    private func startConnectingTimer() {
        connectingTimer?.cancel()
        connectingTooLong = false
        connectingTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.connectingTooLong = true
        }
    }

    // MARK: - Stream Message Processing

    private func processStreamMessage(_ streamMessage: StreamMessage) {
        switch streamMessage {
        case .assistant(let assistantMsg):
            // Find or create current assistant message
            var currentMessage: ChatMessage
            if let lastMessage = messages.last, !lastMessage.isUser {
                currentMessage = lastMessage
                messages.removeLast()
            } else {
                currentMessage = ChatMessage(isUser: false, text: "")
            }

            for block in assistantMsg.content {
                switch block {
                case .text(let textBlock):
                    // CRITICAL: Use assignment, not append.
                    // The assistant event contains accumulated text.
                    // Using += would duplicate: "Hello" -> "HelloHello"
                    currentMessage.text = textBlock.text
                case .toolUse(let toolBlock):
                    currentMessage.toolCalls.append(toolBlock.name)
                case .thinking(let thinkingBlock):
                    currentMessage.thinking = thinkingBlock.thinking
                default:
                    break
                }
            }

            messages.append(currentMessage)
            streamTokenCount = max(streamTokenCount, currentMessage.text.count / 4)

        case .streamEvent(let event):
            guard let delta = event.delta else { return }

            var currentMessage: ChatMessage
            if let lastMessage = messages.last, !lastMessage.isUser {
                currentMessage = lastMessage
                messages.removeLast()
            } else {
                currentMessage = ChatMessage(isUser: false, text: "")
            }

            switch delta {
            case .textDelta(let text):
                // For deltas, += is correct — each delta is incremental
                currentMessage.text += text
            case .thinkingDelta(let thinking):
                currentMessage.thinking = (currentMessage.thinking ?? "") + thinking
            case .inputJsonDelta:
                break
            }

            messages.append(currentMessage)

        case .result(let resultMsg):
            if let lastMessage = messages.last, !lastMessage.isUser {
                var updated = lastMessage
                messages.removeLast()
                updated.cost = resultMsg.totalCostUSD
                messages.append(updated)
            }

        case .error(let errorMsg):
            if let lastMessage = messages.last, !lastMessage.isUser {
                var updated = lastMessage
                messages.removeLast()
                updated.text += "\n\nError: \(errorMsg.message)"
                messages.append(updated)
            }

        case .system, .user:
            break
        }
    }
}

// MARK: - Chat Message Model

/// A single message in the chat conversation.
struct ChatMessage: Identifiable {
    let id = UUID()
    let isUser: Bool
    var text: String
    var toolCalls: [String] = []
    var thinking: String?
    var cost: Double?
    let timestamp = Date()
}
