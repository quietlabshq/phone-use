#!/usr/bin/env python3
"""Exercise the Linux phone-use executable over its real MCP stdio transport."""

import base64
import json
import select
import subprocess
import sys


def main() -> int:
    command = sys.argv[1:]
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        print("usage: test-linux-stdio.py -- <executable and arguments>", file=sys.stderr)
        return 2

    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, bufsize=1)

    def send(message: dict) -> None:
        assert process.stdin is not None
        process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
        process.stdin.flush()

    def response_for(request_id: int | str) -> dict:
        assert process.stdout is not None
        while True:
            ready, _, _ = select.select([process.stdout], [], [], 5)
            if not ready:
                raise RuntimeError(f"timed out waiting for MCP response {request_id!r}")
            line = process.stdout.readline()
            if not line:
                raise RuntimeError("MCP process closed stdout before replying")
            response = json.loads(line)
            if response.get("id") == request_id:
                return response

    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "linux-smoke", "version": "1"}}})
        initialization = response_for(1)
        assert initialization["result"]["protocolVersion"] == "2025-11-25"
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})

        send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        tools = response_for(2)["result"]["tools"]
        assert len(tools) == 9

        send({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
            "name": "list_phones", "arguments": {}}})
        phones = response_for(3)["result"]["content"][0]["text"]
        assert "fake-iphone | Fake iPhone" in phones

        send({"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {
            "name": "screenshot", "arguments": {}}})
        screenshot = response_for(4)["result"]["content"][0]
        assert screenshot["type"] == "image" and screenshot["mimeType"] == "image/jpeg"
        jpeg = base64.b64decode(screenshot["data"])
        assert len(jpeg) > 100 and jpeg.startswith(bytes([0xFF, 0xD8])) and jpeg.endswith(bytes([0xFF, 0xD9]))

        send({"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {
            "name": "tap", "arguments": {"x": 1, "y": 1}}})
        assert response_for(5)["result"]["content"][0]["text"] == "OK"

        send({"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {
            "name": "not_a_tool", "arguments": {}}})
        assert response_for(6)["result"]["isError"] is True
        print("Linux MCP stdio smoke passed: initialize, tools/list, fake discovery, screenshot, action, error")
        return 0
    finally:
        if process.stdin is not None:
            process.stdin.close()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, RuntimeError, json.JSONDecodeError) as error:
        print(f"Linux MCP stdio smoke failed: {error}", file=sys.stderr)
        raise SystemExit(1)
