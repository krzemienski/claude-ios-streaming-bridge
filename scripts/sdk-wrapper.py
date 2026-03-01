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

SDK Pattern: Uses isinstance() checks per official Claude Agent SDK docs.
See: https://docs.claude.com/agent-sdk/python
"""

import sys
import json
import asyncio


def emit(obj):
    """Write a JSON object as an NDJSON line to stdout.

    Uses compact separators to minimize bandwidth and flush=True
    to ensure real-time delivery to the parent process.
    """
    line = json.dumps(obj, separators=(",", ":"))
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def convert_content_block(block):
    """Convert a Claude Agent SDK content block to StreamMessage-compatible dict."""
    from claude_agent_sdk import (
        TextBlock, ThinkingBlock, ToolUseBlock, ToolResultBlock,
    )

    if isinstance(block, TextBlock):
        return {"type": "text", "text": block.text}
    elif isinstance(block, ToolUseBlock):
        return {
            "type": "tool_use",
            "id": block.id,
            "name": block.name,
            "input": block.input,
        }
    elif isinstance(block, ToolResultBlock):
        return {
            "type": "tool_result",
            "tool_use_id": block.tool_use_id,
            "content": block.content,
            "is_error": getattr(block, "is_error", False),
        }
    elif isinstance(block, ThinkingBlock):
        return {"type": "thinking", "thinking": block.thinking}
    else:
        # Fallback for unknown block types
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
    from claude_agent_sdk import (
        query, ClaudeAgentOptions,
        AssistantMessage, UserMessage, SystemMessage, ResultMessage,
        TextBlock, ThinkingBlock, ToolUseBlock, ToolResultBlock,
    )

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
            if isinstance(message, AssistantMessage):
                content_blocks = [convert_content_block(b) for b in message.content]
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

            elif isinstance(message, ResultMessage):
                got_result = True
                result = {
                    "type": "result",
                    "subtype": "error" if message.is_error else "success",
                    "is_error": message.is_error,
                    "session_id": getattr(message, "session_id", session_id),
                    "total_cost_usd": message.total_cost_usd or 0.0,
                }
                if hasattr(message, "usage") and message.usage:
                    usage = message.usage
                    result["usage"] = {
                        "input_tokens": usage.get("input_tokens", 0) if isinstance(usage, dict) else getattr(usage, "input_tokens", 0),
                        "output_tokens": usage.get("output_tokens", 0) if isinstance(usage, dict) else getattr(usage, "output_tokens", 0),
                        "cache_read_input_tokens": usage.get("cache_read_input_tokens", 0) if isinstance(usage, dict) else getattr(usage, "cache_read_input_tokens", 0),
                        "cache_creation_input_tokens": usage.get("cache_creation_input_tokens", 0) if isinstance(usage, dict) else getattr(usage, "cache_creation_input_tokens", 0),
                    }
                emit(result)

            elif isinstance(message, UserMessage):
                content_blocks = [convert_content_block(b) for b in message.content]
                emit({
                    "type": "user",
                    "message": {"role": "user", "content": content_blocks},
                })

            elif isinstance(message, SystemMessage):
                pass  # System messages during conversation

            else:
                print(f"sdk-wrapper: unknown message type: {type(message).__name__}", file=sys.stderr)

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
    """Entry point: parse JSON config from argv[1] and run the bridge.

    Usage:
        python3 sdk-wrapper.py '{"prompt":"Hello","options":{}}'

    The config dict must contain 'prompt' (str). Optional keys:
        - options.model (str): Claude model to use
        - options.maxTokens (int): Max response tokens
        - session_id (str): Session identifier for tracking
    """
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
