"""ACP peer for session mode selection and configuration updates."""
import json
import sys
import time

variant = sys.argv[1]
modern = variant.startswith("config")
current = "plan" if variant.endswith("load") else "build"


def send(message):
    print(json.dumps(dict(jsonrpc="2.0", **message)), flush=True)


def notify(update):
    send({"method": "session/update", "params": {"sessionId": "modes-session", "update": update}})


def settings():
    choices = [{"id": "build", "name": "Build"}, {"id": "plan", "name": "Plan"},
               {"id": "reject", "name": "Rejected Mode"}]
    if modern:
        option = {
            "id": "workflow", "name": "Session Mode", "type": "select", "currentValue": current,
            "options": [{"group": "agents", "name": "Agents", "options": [
                {"value": c["id"], "name": c["name"]} for c in choices
            ]}],
        }
        if variant != "config-no-category":
            option["category"] = "mode"
        return {"configOptions": [option, {
            "id": "model", "category": "model", "name": "Model", "type": "select",
            "currentValue": "alpha" if current == "build" else "beta",
            "options": [{"value": "alpha", "name": "Alpha"}, {"value": "beta", "name": "Beta"}],
        }], "modes": {"currentModeId": "obsolete", "availableModes": [{"id": "obsolete", "name": "Obsolete"}]}}
    if variant.startswith("legacy"):
        return {"modes": {"currentModeId": current, "availableModes": choices}}
    return {}


for line in sys.stdin:
    request = json.loads(line)
    method, params = request.get("method"), request.get("params", {})
    result = {}
    if method == "initialize":
        result = {"agentCapabilities": {"loadSession": True}}
    elif method in {"session/new", "session/load"}:
        if variant.endswith("load"):
            assert method == "session/load"
        notify({"sessionUpdate": "available_commands_update", "availableCommands": [
            {"name": "mode", "description": "Agent mode command"}
        ]})
        result = dict(sessionId="modes-session", **settings())
    elif method in {"session/set_config_option", "session/set_mode"}:
        assert params["sessionId"] == "modes-session"
        if modern:
            assert method == "session/set_config_option" and params["configId"] == "workflow"
            selected = params["value"]
        else:
            assert variant.startswith("legacy") and method == "session/set_mode"
            selected = params["modeId"]
        if selected == "reject":
            send({"id": request["id"], "error": {"code": -32602, "message": "Mode unavailable"}})
            continue
        current = selected
        time.sleep(0.05)
        if modern:
            result = {"configOptions": settings()["configOptions"]}
            notify(dict(sessionUpdate="config_option_update", **result))
        elif variant == "legacy-notify":
            notify({"sessionUpdate": "current_mode_update", "currentModeId": current})
    elif method == "session/prompt":
        text = params["prompt"][0]["text"]
        assert not (text == "/mode" or text.startswith("/mode ")), "local command sent as prompt"
        if text == "agent-update":
            current = "build"
            if modern:
                notify(dict(sessionUpdate="config_option_update", configOptions=settings()["configOptions"]))
            else:
                notify({"sessionUpdate": "current_mode_update", "currentModeId": current})
        time.sleep(0.05)
        notify({"sessionUpdate": "agent_message_chunk", "content": {
            "type": "text", "text": "reply in " + current + ": " + text
        }})
        result = {"stopReason": "end_turn"}
    if "id" in request:
        send({"id": request["id"], "result": result})
