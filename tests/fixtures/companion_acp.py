"""Deterministic ACP peer for the companion integration/browser checks."""
import json
import sys
import time

pending = None
serial = 0


def send(**message):
    print(json.dumps({'jsonrpc': '2.0', **message}), flush=True)


def chunk(text):
    send(method='session/update', params={'update': {
        'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': text}}})


for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if method == 'initialize':
        send(id=request['id'], result={'agentCapabilities': {}, 'agentInfo': {'name': 'companion-fixture'}})
    elif method == 'session/new':
        send(id=request['id'], result={'sessionId': 'companion-conversation'})
    elif method == 'session/prompt':
        text = request['params']['prompt'][0]['text']
        if text in ('permission', 'hold'):
            pending = request['id']
            serial += 1
            chunk('Reviewing your request.\n')
            send(id=f'permission-{serial}', method='session/request_permission', params={
                'toolCall': {'toolCallId': f'tool-{serial}', 'title': 'Read example.txt'},
                'options': [{'optionId': 'allow', 'name': 'Allow once', 'kind': 'allow_once'},
                            {'optionId': 'reject', 'name': 'Reject once', 'kind': 'reject_once'}]})
        else:
            chunk('Streamed response: ')
            time.sleep(.7)
            chunk(text)
            send(id=request['id'], result={'stopReason': 'end_turn'})
    elif method == 'session/cancel':
        if pending is not None:
            send(id=pending, result={'stopReason': 'cancelled'})
            pending = None
    elif method is None and request.get('result') and pending is not None:
        outcome = request['result']['outcome']
        if outcome['outcome'] == 'selected':
            chunk('\nPermission answered: ' + outcome['optionId'])
            send(id=pending, result={'stopReason': 'end_turn'})
            pending = None
