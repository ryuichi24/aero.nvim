"""Small ACP peer for exercising history restoration without a real agent."""
import json
import sys

mode = sys.argv[1]


def send(message):
    print(json.dumps(dict(jsonrpc="2.0", **message)), flush=True)


def update(kind, text):
    send({"method": "session/update", "params": {"update": {
        "sessionUpdate": kind, "content": {"type": "text", "text": text}
    }}})


for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    result = {}
    if method == "initialize":
        result = {"agentCapabilities": {"loadSession": mode != "unsupported"}}
    elif method == "session/new":
        assert mode not in {"replay", "recover-id", "fail", "recover", "recover-fail", "missing-rollout", "replay-recovered"}, "expected session/load, got session/new"
        result = {"sessionId": "fixture-session"}
    elif method == "session/load":
        expected = {"recover": "recovered-session", "recover-fail": "broken-recovery", "missing-rollout": "missing-session", "replay-recovered": "recovered-session"}.get(mode, "fixture-session")
        assert request["params"]["sessionId"] == expected
        if mode in {"missing-rollout", "recover-fail"}:
            send({"id": request["id"], "error": {"code": -32603, "message": "Internal error", "data": {"details": "no rollout found for thread id " + expected}}})
            continue
        recovered = mode in {"recover", "replay-recovered"}
        update("user_message_chunk", "recovered question" if recovered else "old question")
        update("agent_message_chunk", "recovered answer" if recovered else "old answer")
        if mode == "fail":
            send({"id": request["id"], "error": {
                "code": -32603, "message": "Internal error",
                "data": {"reason": "fixture: failed to read saved rollout", "path": "/fixture/rollout.jsonl"}
            }})
            continue
    elif method == "session/prompt":
        assert mode != "fail", "prompt was sent after a failed session/load"
        assert request["params"]["sessionId"] == "fixture-session"
        if mode == "save":
            update("agent_thought_chunk", "old thought")
            for event in [
                {"sessionUpdate": "tool_call", "toolCallId": "fixture-tool",
                 "title": "old tool", "status": "completed", "content": [
                     {"type": "content", "content": {"type": "text", "text": "old tool output"}}
                 ]},
                {"sessionUpdate": "plan", "entries": [{"content": "old plan", "status": "completed"}]},
            ]:
                send({"method": "session/update", "params": {"update": event}})
        update("agent_message_chunk", "old answer" if mode == "save" else "new answer")
        result = {"stopReason": "end_turn"}
    if "id" in request:
        send({"id": request["id"], "result": result})
