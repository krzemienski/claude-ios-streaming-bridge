import SwiftUI
import StreamingBridge

/// Example SwiftUI app demonstrating the StreamingBridge package.
///
/// This app provides a minimal chat interface that connects to a
/// Vapor backend running on localhost:9999 and streams Claude Code
/// responses via Server-Sent Events.
///
/// ## Prerequisites
///
/// 1. A running Vapor backend with the `/api/v1/chat/stream` endpoint
/// 2. Claude Code installed and authenticated (OAuth)
/// 3. The `sdk-wrapper.py` script in the backend's `scripts/` directory
/// 4. `pip install claude-agent-sdk`
@main
struct StreamingBridgeExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ChatView()
        }
    }
}
