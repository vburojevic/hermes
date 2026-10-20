#!/usr/bin/env python3
"""Minimal stdio client for `cua-driver mcp`, so text typed into a GUI (e.g. a password)
travels over a pipe instead of a command line. Import and use `Driver`."""
import json
import subprocess


class Driver:
    def __init__(self):
        self.proc = subprocess.Popen(
            ["cua-driver", "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True
        )
        self.next_id = 0
        self._rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "hermes-release", "version": "1"}})
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _send(self, message):
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def _rpc(self, method, params):
        self.next_id += 1
        ident = self.next_id
        self._send({"jsonrpc": "2.0", "id": ident, "method": method, "params": params})
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("cua-driver mcp exited")
            message = json.loads(line)
            if message.get("id") == ident:
                return message

    def call(self, tool, arguments):
        reply = self._rpc("tools/call", {"name": tool, "arguments": arguments})
        result = reply.get("result", {})
        structured = result.get("structuredContent")
        if structured is not None:
            return structured
        for part in result.get("content", []):
            if part.get("type") == "text":
                try:
                    return json.loads(part["text"])
                except ValueError:
                    return {"text": part["text"]}
        return result

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=5)


def window_state(driver, pid, window_id, attempts=4):
    """AX snapshot with retries (a busy page can fail a walk)."""
    import time
    last = {}
    for _ in range(attempts):
        last = driver.call("get_window_state", {"pid": pid, "window_id": window_id, "capture_mode": "ax"})
        if "elements" in last:
            return last
        time.sleep(1)
    raise RuntimeError(f"no AX snapshot: {str(last)[:300]}")
