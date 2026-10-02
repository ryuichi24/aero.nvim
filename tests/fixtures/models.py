"""ACP peer for model metadata, setters, and prompt ordering."""
import json
import sys
import time

mode = sys.argv[1]
modern = mode in {"config", "config-no-category", "config-load"}
current = "provider/beta:fast" if mode == "config-load" else "provider/alpha"
if mode == "legacy":
    current = "legacy/alpha"


def send(message):
    print(json.dumps(dict(jsonrpc="2.0", **message)), flush=True)


def notify(update):
    send({"method": "session/update", "params": {"update": update}})


def settings():
    if modern:
        option = {
            "id": "engine", "name": "Model", "type": "select", "currentValue": current,
            "options": [{"group": "provider", "name": "Provider", "options": [
                {"value": "provider/alpha", "name": "Model Alpha"},
                {"value": "provider/beta:fast", "name": "Model Beta"},
                {"value": "provider/reject", "name": "Rejected Model"},
            ]}],
        }
        if mode != "config-no-category":
            option["category"] = "model"
        return {"configOptions": [option, {
            "id": "thought", "name": "Reasoning", "category": "thought_level", "type": "select",
            "currentValue": "high" if current == "provider/beta:fast" else "low", "options": []
        }], "models": {"currentModelId": "obsolete", "availableModels": [{"modelId": "obsolete", "name": "Legacy Model"}]}}
    if mode == "legacy":
        return {"models": {"currentModelId": current, "availableModels": [
            {"modelId": "legacy/alpha", "name": "Model Alpha"},
            {"modelId": "legacy/beta", "name": "Model Beta"},
        ]}}
    return {}


for line in sys.stdin:
    request = json.loads(line)
    method, params = request.get("method"), request.get("params", {})
    result = {}
    if method == "initialize":
        result = {"agentCapabilities": {"loadSession": True}}
    elif method in {"session/new", "session/load"}:
        if mode == "config-load":
            assert method == "session/load"
            notify(dict(sessionUpdate="config_option_update", configOptions=settings()["configOptions"]))
        notify({"sessionUpdate": "available_commands_update", "availableCommands": [
            {"name": "model", "description": "Agent model command"}, {"name": "help", "description": "Help"}
        ]})
        result = dict(sessionId="models-session", **settings())
    elif method in {"session/set_config_option", "session/set_model"}:
        assert params["sessionId"] == "models-session"
        if modern:
            assert method == "session/set_config_option" and params["configId"] == "engine"
            selected = params["value"]
        else:
            assert mode == "legacy" and method == "session/set_model"
            selected = params["modelId"]
        if selected == "provider/reject":
            send({"id": request["id"], "error": {"code": -32602, "message": "Model unavailable"}})
            continue
        current = selected
        time.sleep(0.05)
        if modern:
            result = {"configOptions": settings()["configOptions"]}
            notify(dict(sessionUpdate="config_option_update", **result))
    elif method == "session/prompt":
        text = params["prompt"][0]["text"]
        assert not (text == "/model" or text.startswith("/model ")), "local command was sent as a model prompt"
        if text == "agent-update" and modern:
            current = "provider/alpha"
            notify(dict(sessionUpdate="config_option_update", configOptions=settings()["configOptions"]))
        time.sleep(0.05)
        notify({"sessionUpdate": "agent_message_chunk", "content": {
            "type": "text", "text": "reply using " + current + ": " + text
        }})
        result = {"stopReason": "end_turn"}
    if "id" in request:
        send({"id": request["id"], "result": result})
