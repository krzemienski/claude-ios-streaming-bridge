import SwiftUI
import StreamingBridge

/// Example chat interface using the StreamingBridge package.
///
/// Demonstrates:
/// - Real-time SSE streaming with connection state indicators
/// - Message rendering with user/assistant differentiation
/// - Auto-scrolling to new messages
/// - Stream cancellation
/// - Cost and token count display
struct ChatView: View {
    @State private var viewModel = ChatViewModel()
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Connection status bar
                if let statusText = viewModel.statusText {
                    HStack(spacing: 8) {
                        if viewModel.isStreaming {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                }

                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.messages.count) {
                        if let lastMessage = viewModel.messages.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                // Streaming stats
                if viewModel.isStreaming {
                    HStack {
                        Text("~\(viewModel.streamTokenCount) tokens")
                        Spacer()
                        Text(String(format: "%.1fs", viewModel.streamElapsedSeconds))
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal)
                    .padding(.top, 4)
                }

                // Input bar
                HStack(spacing: 12) {
                    TextField("Message Claude...", text: $inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .focused($isInputFocused)
                        .onSubmit { send() }

                    if viewModel.isStreaming {
                        Button {
                            viewModel.cancelStream()
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.red)
                        }
                    } else {
                        Button {
                            send()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                                .foregroundStyle(inputText.isEmpty ? .tertiary : .blue)
                        }
                        .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
            .navigationTitle("StreamingBridge Demo")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""
        viewModel.sendMessage(text)
    }
}

// MARK: - Message Bubble

/// Renders a single chat message with appropriate styling.
private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 60) }

            VStack(alignment: .leading, spacing: 6) {
                // Tool calls indicator
                if !message.toolCalls.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.caption2)
                        Text(message.toolCalls.joined(separator: ", "))
                            .font(.caption2)
                    }
                    .foregroundStyle(.orange)
                }

                // Thinking indicator
                if let thinking = message.thinking, !thinking.isEmpty {
                    DisclosureGroup("Thinking...") {
                        Text(thinking)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .foregroundStyle(.purple)
                }

                // Message text
                Text(message.text)
                    .textSelection(.enabled)

                // Cost display
                if let cost = message.cost {
                    Text(String(format: "$%.4f", cost))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                message.isUser
                    ? Color.blue.opacity(0.15)
                    : Color.secondary.opacity(0.08)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if !message.isUser { Spacer(minLength: 60) }
        }
    }
}

#Preview {
    ChatView()
}
