"""ACP peer that exercises the real Aero MCP executable and write protection."""
import json
import os
import subprocess
import sys


def send(message):
    print(json.dumps(dict(jsonrpc="2.0", **message)), flush=True)


adapter = None
descriptor = None
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        send({"id": request["id"], "result": {"agentCapabilities": {"loadSession": True}}})
    elif method in {"session/new", "session/load"}:
        descriptor = request["params"]["mcpServers"][0]
        assert descriptor["name"] == "aero-tasks"
        assert os.path.isabs(descriptor["command"])
        env = os.environ.copy()
        env.update({item["name"]: item["value"] for item in descriptor["env"]})
        adapter = subprocess.Popen([descriptor["command"], *descriptor["args"]],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=sys.stderr, text=True, env=env)
        counter = 0

        def rpc(method, params):
            global counter
            counter += 1
            adapter.stdin.write(json.dumps(dict(jsonrpc="2.0", id=counter, method=method, params=params)) + "\n")
            adapter.stdin.flush()
            while True:
                response = json.loads(adapter.stdout.readline())
                if response.get("id") == counter:
                    assert "error" not in response, response
                    return response["result"]

        rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "acp-fixture", "version": "1"}})
        adapter.stdin.write(json.dumps(dict(jsonrpc="2.0", method="notifications/initialized")) + "\n")
        adapter.stdin.flush()
        assert len(rpc("tools/list", {})["tools"]) == 6
        send({"id": request["id"], "result": {"sessionId": "task-fixture"}})
    elif method == "session/prompt":
        def tool(name, arguments):
            result = rpc("tools/call", {"name": "aero_" + name, "arguments": arguments})
            assert not result.get("isError"), result
            return json.loads(result["content"][0]["text"])

        read = tool("get_ticket", {})
        moved = tool("move_ticket", {"operation_id": "fixture-move", "expected_board_revision": read["board_revision"],
                                    "expected_state": read["state"], "target_state": "in progress"})
        updated = tool("update_ticket_body", {"operation_id": "fixture-body", "expected_ticket_revision": moved["ticket_revision"],
                                              "body": "\nImplemented and verified via ACP/MCP fixture.\n"})
        tool("move_ticket", {"operation_id": "fixture-review", "expected_board_revision": updated["board_revision"],
                             "expected_state": "in progress", "target_state": "review"})
        send({"id": "unsafe-write", "method": "fs/write_text_file", "params": {"path": read["ticket_path"], "content": "erase identity"}})
        response = json.loads(sys.stdin.readline())
        assert response["id"] == "unsafe-write" and "error" in response, response
        send({"method": "session/update", "params": {"update": {"sessionUpdate": "agent_message_chunk",
              "content": {"type": "text", "text": "Task tools verified"}}}})
        send({"id": request["id"], "result": {"stopReason": "end_turn"}})
    elif method == "session/cancel":
        pass
if adapter:
    adapter.terminate()
