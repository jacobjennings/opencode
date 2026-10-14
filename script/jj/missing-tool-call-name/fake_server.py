"""Fake OpenAI-compatible chat server for the missing tool-call name test.

Emulates the SGLang qwen3_coder stream from the 9 October incident: the first
tool-bearing request streams a named bash tool call; the first request that
carries a tool result streams a text part, then a tool call whose FIRST delta
has no function.name.

MODE "missing": the name never arrives and the stream ends without a finish
reason (the stock build fails with "Expected 'function.name' to be a string").
The next such request streams clean text "FAKE-DONE".
MODE "late": the name arrives in a later delta of the same tool call, and the
request after that streams clean text "FAKE-DONE".
MODE "retry-text": the first tool-bearing attempt streams the fixed text
"RETRY-TEXT-SENTINEL-7Q" and then a tool call with no function.name, ending the
stream without a finish reason; every retried attempt streams the same fixed
text and then finishes normally.

Requests that carry no tools (e.g. title generation) get plain text and never
emit tool calls. Every request body is appended to requests.jsonl.
Usage: python3 -I fake_server.py PORT OUTDIR MODE
"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, OUT, MODE = int(sys.argv[1]), sys.argv[2], sys.argv[3]
state = {'n_tool_result': 0, 'n_stream_tools': 0}


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

    def send_stream(self, events, tail=True):
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        for e in events:
            self.wfile.write(f'data: {json.dumps(e)}\n\n'.encode())
            self.wfile.flush()
        if tail:
            usage = {'id': 'chatcmpl-fake', 'object': 'chat.completion.chunk', 'created': 0, 'model': 'fake-model',
                     'choices': [], 'usage': {'prompt_tokens': 1, 'completion_tokens': 1, 'total_tokens': 2}}
            self.wfile.write(f'data: {json.dumps(usage)}\n\ndata: [DONE]\n\n'.encode())
            self.wfile.flush()

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
        args = json.dumps({'command': 'echo FAKE-TOOL-RAN', 'description': 'Print a marker'})
        if not req.get('tools'):
            # Streamed requests that carry no tools: title generation etc.
            self.send_stream([chunk({'role': 'assistant', 'content': 'fake title'}), chunk({}, 'stop')])
            return
        if MODE == 'retry-text':
            # The first tool-bearing attempt streams a fixed text, then a malformed
            # tool call with no function.name, and the stream ends without a finish
            # reason. Every retried attempt streams the same fixed text and then
            # finishes normally. This proves the retried attempt's text part is
            # removed so the persisted session keeps the sentinel exactly once.
            state['n_stream_tools'] += 1
            if state['n_stream_tools'] == 1:
                self.send_stream([
                    chunk({'role': 'assistant', 'content': 'RETRY-TEXT-SENTINEL-7Q'}),
                    chunk({'tool_calls': [{'index': 0, 'type': 'function',
                                            'function': {'arguments': ''}}]}),
                    chunk({'tool_calls': [{'index': 0, 'function': {'arguments': args}}]}),
                ], tail=False)
            else:
                self.send_stream([
                    chunk({'role': 'assistant', 'content': 'RETRY-TEXT-SENTINEL-7Q'}),
                    chunk({}, 'stop'),
                ])
            return
        if has_tool_result:
            state['n_tool_result'] += 1
            n = state['n_tool_result']
            if MODE == 'missing' and n == 1:
                # The incident shape: step start, text part, then a tool call whose
                # first delta has no function.name, then the stream ends. No finish
                # reason, no tool_use event.
                self.send_stream([
                    chunk({'role': 'assistant', 'content': ''}),
                    chunk({'role': 'assistant', 'content': 'FAKE-TEXT-STEP2'}),
                    chunk({'tool_calls': [{'index': 0, 'type': 'function',
                                           'function': {'arguments': ''}}]}),
                    chunk({'tool_calls': [{'index': 0, 'function': {'arguments': args}}]}),
                ], tail=False)
                return
            if MODE == 'late' and n == 1:
                # Same start, but the name arrives in a later delta.
                self.send_stream([
                    chunk({'role': 'assistant', 'content': ''}),
                    chunk({'role': 'assistant', 'content': 'FAKE-TEXT-STEP2'}),
                    chunk({'tool_calls': [{'index': 0, 'type': 'function',
                                           'function': {'arguments': ''}}]}),
                    chunk({'tool_calls': [{'index': 0, 'function': {'name': 'bash', 'arguments': ''}}]}),
                    chunk({'tool_calls': [{'index': 0, 'function': {'arguments': args}}]}),
                    chunk({}, 'tool_calls'),
                ])
                return
            # Subsequent requests (retry after a broken step, or the second tool
            # result in "late" mode) finish with plain text.
            self.send_stream([chunk({'role': 'assistant', 'content': 'FAKE-DONE'}), chunk({}, 'stop')])
            return
        # First tool-bearing request: a well-formed tool call, as before the incident.
        self.send_stream([
            chunk({'role': 'assistant', 'content': ''}),
            chunk({'tool_calls': [{'index': 0, 'type': 'function',
                                   'id': 'call-1', 'function': {'name': 'bash', 'arguments': ''}}]}),
            chunk({'tool_calls': [{'index': 0, 'function': {'arguments': args}}]}),
            chunk({}, 'tool_calls'),
        ])


HTTPServer(('127.0.0.1', PORT), H).serve_forever()
