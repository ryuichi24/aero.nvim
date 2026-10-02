"""ACP peer reporting response tokens, cumulative fees, and context snapshots."""
import json
import sys

mode = sys.argv[1]
turn = 0


def send(message):
    print(json.dumps(dict(jsonrpc="2.0", **message)), flush=True)


def update(value):
    send({"method": "session/update", "params": {"update": value}})


def usage(used, amount):
    value = {"sessionUpdate": "usage_update", "used": used, "size": 10000,
             "cost": {"amount": amount, "currency": "USD"}}
    update(value)
    update(value)  # Repeated cumulative snapshots must never be charged twice.


for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    result = {}
    if method == "initialize":
        result = {"agentCapabilities": {"loadSession": True}}
    elif method == "session/new":
        result = {"sessionId": "new-usage-session" if mode == "new" else "usage-session"}
    elif method == "session/load":
        if request["params"]["sessionId"] == "broken-usage":
            usage(99, 99)
            send({"id": request["id"], "error": {"code": -32603, "message": "failed usage recovery"}})
            continue
        turn = 3 if mode == "failure" else 2
        usage(3500 if mode == "failure" else 3000, 0.03 if mode == "failure" else 0.02)
        update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "replayed answer"}})
    elif method == "session/prompt":
        turn += 1
        if turn == 1:
            usage(5000, 0.0125)
            tokens = {"inputTokens": 1200, "outputTokens": 300, "totalTokens": 1600,
                      "thoughtTokens": 50, "cachedReadTokens": 40, "cachedWriteTokens": 10}
        else:
            usage(3000 if turn == 2 else 3500, 0.02 if turn == 2 else 0.03)
            tokens = {"inputTokens": 200, "outputTokens": 40, "totalTokens": 260,
                      "thoughtTokens": 10, "cachedReadTokens": 10}
        update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "reply " + str(turn)}})
        result = {"stopReason": "end_turn", "usage": tokens}
    if "id" in request:
        send({"id": request["id"], "result": result})
