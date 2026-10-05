"""Strict saved-conversation ACP fixture: session/new is never accepted."""
import json
import sys

variant, log = sys.argv[1:3]


def send(message):
    print(json.dumps(dict(jsonrpc="2.0", **message)), flush=True)


for line in sys.stdin:
    request = json.loads(line)
    method, params = request.get("method"), request.get("params", {})
    with open(log, "a", encoding="utf-8") as output:
        output.write(json.dumps({"method": method, "params": params}) + "\n")
    if method == "initialize":
        if variant == "initialize-error":
            send({"id": request["id"], "error": {"code": -32000, "message": "initialize rejected"}})
            continue
        result = {"agentCapabilities": {"loadSession": variant != "unsupported"}}
    elif method == "session/load":
        assert params["sessionId"] == "saved-ticket-conversation"
        assert params["mcpServers"][0]["name"] == "aero-tasks"
        if variant == "reject":
            send({"id": request["id"], "error": {"code": -32000, "message": "load rejected"}})
            continue
        for kind, text in [("user_message_chunk", "Saved question"), ("agent_message_chunk", "Saved answer")]:
            send({"method": "session/update", "params": {
                "sessionId": params["sessionId"],
                "update": {"sessionUpdate": kind, "content": {"type": "text", "text": text}},
            }})
        result = {"modes": {"currentModeId": "plan", "availableModes": [{"id": "plan", "name": "Plan"}]}}
    else:
        raise AssertionError("Unexpected request: " + str(method))
    if "id" in request:
        send({"id": request["id"], "result": result})
