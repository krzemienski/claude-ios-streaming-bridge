import Foundation

// MARK: - Top-Level Stream Message

/// Top-level streaming message from Claude Code.
///
/// Each message arriving over the SSE connection is decoded into one of these cases.
/// The `type` field in the JSON determines which case applies.
public enum StreamMessage: Codable, Sendable {
    /// System initialization or control message.
    case system(SystemMessage)
    /// Assistant response with content blocks.
    case assistant(AssistantMessage)
    /// User message (tool results from agent).
    case user(UserMessage)
    /// Final result message with usage and cost information.
    case result(ResultMessage)
    /// Stream event for character-by-character delivery.
    case streamEvent(StreamEventMessage)
    /// Error message from the stream.
    case error(StreamError)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "system":
            self = .system(try SystemMessage(from: decoder))
        case "assistant":
            self = .assistant(try AssistantMessage(from: decoder))
        case "user":
            self = .user(try UserMessage(from: decoder))
        case "result":
            self = .result(try ResultMessage(from: decoder))
        case "streamEvent":
            self = .streamEvent(try StreamEventMessage(from: decoder))
        case "error":
            self = .error(try StreamError(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown stream message type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .system(let msg):    try msg.encode(to: encoder)
        case .assistant(let msg): try msg.encode(to: encoder)
        case .user(let msg):      try msg.encode(to: encoder)
        case .result(let msg):    try msg.encode(to: encoder)
        case .streamEvent(let msg): try msg.encode(to: encoder)
        case .error(let msg):     try msg.encode(to: encoder)
        }
    }
}

// MARK: - System Message

/// System message containing session initialization data.
public struct SystemMessage: Codable, Sendable {
    public let type: String
    public let subtype: String
    public let data: SystemData

    public init(type: String = "system", subtype: String = "init", data: SystemData) {
        self.type = type
        self.subtype = subtype
        self.data = data
    }
}

/// System initialization data from Claude Code.
public struct SystemData: Codable, Sendable {
    public let sessionId: String
    public let tools: [String]?
    public let model: String?
    public let cwd: String?

    public init(sessionId: String, tools: [String]? = nil, model: String? = nil, cwd: String? = nil) {
        self.sessionId = sessionId
        self.tools = tools
        self.model = model
        self.cwd = cwd
    }
}

// MARK: - Assistant Message

/// Assistant response message containing content blocks.
public struct AssistantMessage: Codable, Sendable {
    public let type: String
    public let content: [ContentBlock]
    public let sessionId: String?

    public init(type: String = "assistant", content: [ContentBlock], sessionId: String? = nil) {
        self.type = type
        self.content = content
        self.sessionId = sessionId
    }
}

// MARK: - User Message

/// User message containing tool results from agent.
public struct UserMessage: Codable, Sendable {
    public let type: String
    public let content: [ContentBlock]

    public init(type: String = "user", content: [ContentBlock] = []) {
        self.type = type
        self.content = content
    }
}

// MARK: - Content Block

/// A single content block within an assistant or user message.
public enum ContentBlock: Codable, Sendable {
    case text(TextBlock)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)
    case thinking(ThinkingBlock)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            self = .text(try TextBlock(from: decoder))
        case "tool_use", "toolUse":
            self = .toolUse(try ToolUseBlock(from: decoder))
        case "tool_result", "toolResult":
            self = .toolResult(try ToolResultBlock(from: decoder))
        case "thinking":
            self = .thinking(try ThinkingBlock(from: decoder))
        default:
            // Fall back to text with raw description
            self = .text(TextBlock(text: "[Unknown block type: \(type)]"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let block):       try block.encode(to: encoder)
        case .toolUse(let block):    try block.encode(to: encoder)
        case .toolResult(let block): try block.encode(to: encoder)
        case .thinking(let block):   try block.encode(to: encoder)
        }
    }
}

/// A text content block.
public struct TextBlock: Codable, Sendable {
    public let type: String
    public let text: String

    public init(type: String = "text", text: String) {
        self.type = type
        self.text = text
    }
}

/// A tool use content block.
public struct ToolUseBlock: Codable, Sendable {
    public let type: String
    public let id: String
    public let name: String

    public init(type: String = "tool_use", id: String, name: String) {
        self.type = type
        self.id = id
        self.name = name
    }
}

/// A tool result content block.
public struct ToolResultBlock: Codable, Sendable {
    public let type: String
    public let toolUseId: String
    public let content: String
    public let isError: Bool

    public init(type: String = "tool_result", toolUseId: String, content: String, isError: Bool = false) {
        self.type = type
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
    }
}

/// A thinking content block (extended thinking).
public struct ThinkingBlock: Codable, Sendable {
    public let type: String
    public let thinking: String

    public init(type: String = "thinking", thinking: String) {
        self.type = type
        self.thinking = thinking
    }
}

// MARK: - Stream Event Message

/// Stream event for character-by-character delivery.
public struct StreamEventMessage: Codable, Sendable {
    public let type: String
    public let eventType: String
    public let index: Int?
    public let delta: StreamDelta?

    public init(type: String = "streamEvent", eventType: String, index: Int? = nil, delta: StreamDelta? = nil) {
        self.type = type
        self.eventType = eventType
        self.index = index
        self.delta = delta
    }
}

/// Delta content for streaming events.
public enum StreamDelta: Codable, Sendable {
    case textDelta(String)
    case inputJsonDelta(String)
    case thinkingDelta(String)

    private enum CodingKeys: String, CodingKey {
        case type, text, partialJson, thinking
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text_delta", "textDelta":
            let text = try container.decode(String.self, forKey: .text)
            self = .textDelta(text)
        case "input_json_delta", "inputJsonDelta":
            let json = try container.decode(String.self, forKey: .partialJson)
            self = .inputJsonDelta(json)
        case "thinking_delta", "thinkingDelta":
            let thinking = try container.decode(String.self, forKey: .thinking)
            self = .thinkingDelta(thinking)
        default:
            self = .textDelta("")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .textDelta(let text):
            try container.encode("textDelta", forKey: .type)
            try container.encode(text, forKey: .text)
        case .inputJsonDelta(let json):
            try container.encode("inputJsonDelta", forKey: .type)
            try container.encode(json, forKey: .partialJson)
        case .thinkingDelta(let thinking):
            try container.encode("thinkingDelta", forKey: .type)
            try container.encode(thinking, forKey: .thinking)
        }
    }
}

// MARK: - Result Message

/// Final result message with usage and cost information.
public struct ResultMessage: Codable, Sendable {
    public let type: String
    public let subtype: String
    public let sessionId: String
    public let durationMs: Int?
    public let isError: Bool
    public let numTurns: Int?
    public let totalCostUSD: Double?
    public let usage: UsageInfo?
    public let result: String?

    public init(
        type: String = "result",
        subtype: String = "success",
        sessionId: String,
        durationMs: Int? = nil,
        isError: Bool = false,
        numTurns: Int? = nil,
        totalCostUSD: Double? = nil,
        usage: UsageInfo? = nil,
        result: String? = nil
    ) {
        self.type = type
        self.subtype = subtype
        self.sessionId = sessionId
        self.durationMs = durationMs
        self.isError = isError
        self.numTurns = numTurns
        self.totalCostUSD = totalCostUSD
        self.usage = usage
        self.result = result
    }
}

/// Token usage information for a conversation turn.
public struct UsageInfo: Codable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadInputTokens: Int?
    public let cacheCreationInputTokens: Int?

    public init(inputTokens: Int, outputTokens: Int, cacheReadInputTokens: Int? = nil, cacheCreationInputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
    }
}

// MARK: - Stream Error

/// Error message from the streaming API.
public struct StreamError: Codable, Sendable, Error {
    public let type: String
    public let code: String
    public let message: String

    public init(type: String = "error", code: String, message: String) {
        self.type = type
        self.code = code
        self.message = message
    }
}

// MARK: - Chat Stream Request

/// Request payload for initiating a streaming chat with Claude.
public struct ChatStreamRequest: Codable, Sendable {
    public let prompt: String
    public let sessionId: UUID?
    public let options: ChatOptions?

    public init(prompt: String, sessionId: UUID? = nil, options: ChatOptions? = nil) {
        self.prompt = prompt
        self.sessionId = sessionId
        self.options = options
    }
}

/// Options for a chat stream request.
public struct ChatOptions: Codable, Sendable {
    public let model: String?
    public let maxTurns: Int?
    public let systemPrompt: String?
    public let includePartialMessages: Bool?

    public init(
        model: String? = nil,
        maxTurns: Int? = nil,
        systemPrompt: String? = nil,
        includePartialMessages: Bool? = nil
    ) {
        self.model = model
        self.maxTurns = maxTurns
        self.systemPrompt = systemPrompt
        self.includePartialMessages = includePartialMessages
    }
}
