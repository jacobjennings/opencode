"""Fake OpenAI-compatible chat server for the missing tool-call id test.

Request 1 streams a bash tool call whose first delta has no "id" (as SGLang
sometimes sends). Request 2 (after the tool result) streams plain text
"FAKE-DONE" and stops. Every request body is appended to requests.jsonl.
Usage: python3 -I fake_server.py PORT OUTDIR
"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, OUT = int(sys.argv[1]), sys.argv[2]
state = {'n': 0}


def chunk(delta, finish=None):
    return {'id': 'chatcmpl-fake', 'object': 'chat.completion.chunk', 'created': 0,
            'model': 'fake-model',
            'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish}]}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        body = json.dumps({'object': 'list', 'data': [{'id': 'fake-model', 'object': 'model'}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        with open(f'{OUT}/requests.jsonl', 'a') as f:
            f.write(raw.decode(errors='replace') + '\n')
        req = json.loads(raw or b'{}')
        has_tool_result = any(m.get('role') == 'tool' for m in req.get('messages', []))
        if not req.get('stream'):
            # Title generation and other non-streamed calls.
            body = json.dumps({'id': 'x', 'object': 'chat.completion', 'created': 0, 'model': 'fake-model',
                               'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': 'fake title'},
                                            'finish_reason': 'stop'}],
                               'usage': {'prompt_tokens': 1, 'completion_tokens': 1, 'total_tokens': 2}}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        state['n'] += 1
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        if not has_tool_result:
            args = json.dumps({'command': 'echo FAKE-TOOL-RAN', 'description': 'Print a marker'})
            events = [
                chunk({'role': 'assistant', 'content': ''}),
                # First delta of the tool call carries NO id field at all.
                chunk({'tool_calls': [{'index': 0, 'type': 'function',
                                       'function': {'name': 'bash', 'arguments': ''}}]}),
                chunk({'tool_calls': [{'index': 0, 'function': {'arguments': args}}]}),
                chunk({}, 'tool_calls'),
            ]
        else:
            events = [chunk({'role': 'assistant', 'content': 'FAKE-DONE'}), chunk({}, 'stop')]
        for e in events:
            self.wfile.write(f'data: {json.dumps(e)}\n\n'.encode())
            self.wfile.flush()
        usage = {'id': 'chatcmpl-fake', 'object': 'chat.completion.chunk', 'created': 0, 'model': 'fake-model',
                 'choices': [], 'usage': {'prompt_tokens': 1, 'completion_tokens': 1, 'total_tokens': 2}}
        self.wfile.write(f'data: {json.dumps(usage)}\n\ndata: [DONE]\n\n'.encode())
        self.wfile.flush()


HTTPServer(('127.0.0.1', PORT), H).serve_forever()
