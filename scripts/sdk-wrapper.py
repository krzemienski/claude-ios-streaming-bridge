#!/usr/bin/env python3
"""Bridge between Swift ClaudeExecutorService and Claude Agent SDK.

Accepts a JSON config via argv[1], runs claude_agent_sdk.query(),
and emits NDJSON lines on stdout matching the StreamMessage format
expected by the Swift StreamingBridge package.

Usage:
    python3 sdk-wrapper.py '{"prompt":"Hello","options":{}}'

Requirements:
    pip install claude-agent-sdk

Architecture:
    ClaudeExecutorService (Swift) spawns this script as a subprocess.
    This script calls the Claude Agent SDK, which wraps the Claude CLI
    and inherits its OAuth authentication. Each SDK event is converted
    to a JSON line (NDJSON) on stdout.

    The flush=True on every write is critical — without it, Python's
    output buffering delays events by unpredictable amounts, breaking
    the real-time streaming experience. Users would see nothing for
    seconds, then a burst of text, then nothing again.
"""

import sys
import json
import asyncio


# Non-content event types from the SDK that should be silently skipped.
# These are protocol-level events, not user-facing messages.
SKIP_EVENT_TYPES = frozenset({
    "rate_limit_event",
    "rate_limit",
    "ping",
    "heartbeat",
    "error",
    "content_block_start",
    "content_block_stop",
    "content_block_delta",
    "message_start",
    "message_stop",
    "message_delta",
})


def emit(obj):
    """Write a JSON object as an NDJSON line to stdout.

    Uses compact separators to minimize bandwidth and flush=True
    to ensure real-time delivery to the parent process.
    """
    line = json.dumps(obj, separators=(",", ":"))
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def convert_content_block(block):
    """Convert a Claude Agent SDK content block to StreamMessage-compatible dict.

    The SDK uses concrete classes (TextBlock, ThinkingBlock, ToolUseBlock,
    ToolResultBlock) whose .type attribute may not resolve via getattr in all
    SDK versions. Falls back to class name inspection when .type is None.
    """
    block_type = getattr(block, "type", None)

    # Fallback: derive type from class name (e.g., TextBlock -> "text")
    if block_type is None:
        class_name = type(block).__name__.lower()
        if "text" in class_name and "tool" not in class_name:
            block_type = "text"
        elif "thinking" in class_name:
            block_type = "thinking"
        elif "tooluse" in class_name or "tool_use" in class_name:
            block_type = "tool_use"
        elif "toolresult" in class_name or "tool_result" in class_name:
            block_type = "tool_result"

    if block_type == "text":
        return {"type": "text", "text": getattr(block, "text", str(block))}
    elif block_type == "tool_use":
        return {
            "type": "tool_use",
            "id": getattr(block, "id", ""),
            "name": getattr(block, "name", ""),
            "input": getattr(block, "input", {}),
        }
    elif block_type == "tool_result":
        return {
            "type": "tool_result",
            "tool_use_id": getattr(block, "tool_use_id", ""),
            "content": getattr(block, "content", ""),
            "is_error": getattr(block, "is_error", False),
        }
    elif block_type == "thinking":
        return {"type": "thinking", "thinking": getattr(block, "thinking", "")}
    else:
        text = getattr(block, "text", None) or getattr(block, "thinking", None) or str(block)
        return {"type": "text", "text": text}


def build_options(sdk_opts):
    """Build ClaudeAgentOptions from SDK options dict."""
    from claude_agent_sdk import ClaudeAgentOptions

    kwargs = {}

    option_keys = [
        "model", "max_turns", "allowed_tools", "disallowed_tools",
        "permission_mode", "system_prompt", "append_system_prompt",
        "resume", "continue_conversation", "fork_session",
        "session_id", "cwd", "include_partial_messages", "max_budget_usd",
    ]

    for key in option_keys:
        value = sdk_opts.get(key)
        if value is not None:
            kwargs[key] = value

    return ClaudeAgentOptions(**kwargs) if kwargs else ClaudeAgentOptions()


async def run(config):
    """Run a Claude Agent SDK query and emit NDJSON results."""
    from claude_agent_sdk import query

    prompt = config.get("prompt", "")
    sdk_opts = config.get("options", {})
    options = build_options(sdk_opts)
    session_id = sdk_opts.get("session_id", "sdk-session")

    # Emit system init
    emit({
        "type": "system",
        "subtype": "init",
        "data": {"session_id": session_id, "tools": []},
    })

    got_content = False
    got_result = False

    try:
        async for message in query(prompt=prompt, options=options):
            msg_type = getattr(message, "type", None) or type(message).__name__.lower()
            msg_type_lower = msg_type.lower()

            if msg_type in SKIP_EVENT_TYPES or msg_type_lower in SKIP_EVENT_TYPES:
                continue

            if "assistant" in msg_type_lower:
                content_blocks = []
                if hasattr(message, "content"):
                    for block in message.content:
                        content_blocks.append(convert_content_block(block))

                if content_blocks:
                    got_content = True

                emit({
                    "type": "assistant",
                    "message": {
                        "role": "assistant",
                        "content": content_blocks,
                        "model": getattr(message, "model", None),
                    },
                })

            elif "result" in msg_type_lower:
                got_result = True
                result = {
                    "type": "result",
                    "subtype": "error" if getattr(message, "is_error", False) else "success",
                    "is_error": getattr(message, "is_error", False),
                    "session_id": getattr(message, "session_id", session_id),
                    "total_cost_usd": getattr(message, "total_cost_usd", 0.0) or 0.0,
                }

                if hasattr(message, "usage") and message.usage:
                    usage = message.usage
                    result["usage"] = {
                        "input_tokens": getattr(usage, "input_tokens", 0),
                        "output_tokens": getattr(usage, "output_tokens", 0),
                        "cache_read_input_tokens": getattr(usage, "cache_read_input_tokens", 0),
                        "cache_creation_input_tokens": getattr(usage, "cache_creation_input_tokens", 0),
                    }

                emit(result)

            elif "user" in msg_type_lower:
                content_blocks = []
                if hasattr(message, "content"):
                    for block in message.content:
                        content_blocks.append(convert_content_block(block))

                emit({
                    "type": "user",
                    "message": {"role": "user", "content": content_blocks},
                })

            elif "system" in msg_type_lower:
                pass  # Additional system messages during conversation

            else:
                print(f"sdk-wrapper: unknown message type: {msg_type}", file=sys.stderr)

    except Exception as e:
        error_msg = str(e).lower()
        is_benign = (
            "unknown message type" in error_msg
            or "rate_limit" in error_msg
        )

        if is_benign and got_content:
            print(f"sdk-wrapper: ignoring benign SDK exception: {e}", file=sys.stderr)
            if not got_result:
                emit({
                    "type": "result",
                    "subtype": "success",
                    "is_error": False,
                    "session_id": session_id,
                    "total_cost_usd": 0.0,
                })
        else:
            emit({
                "type": "result",
                "subtype": "error",
                "is_error": True,
                "session_id": session_id,
                "total_cost_usd": 0.0,
                "error": str(e),
            })


def main():
    if len(sys.argv) < 2:
        print("Usage: sdk-wrapper.py '<json-config>'", file=sys.stderr)
        sys.exit(1)

    try:
        config = json.loads(sys.argv[1])
    except json.JSONDecodeError as e:
        emit({
            "type": "result",
            "subtype": "error",
            "is_error": True,
            "total_cost_usd": 0.0,
            "error": f"Invalid JSON config: {e}",
        })
        sys.exit(1)

    asyncio.run(run(config))


if __name__ == "__main__":
    main()
