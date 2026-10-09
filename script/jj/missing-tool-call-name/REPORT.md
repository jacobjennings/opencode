# Missing tool-call name: OpenCode side fix (JH-901091)

Incident shape: an OpenAI-compatible provider (SGLang `qwen3_coder`, `--tool-call-parser
deepseekv4`) streams a tool call whose first delta has no `function.name`. In that
shape the stream also ends without a finish reason. OpenCode 0.0.0-202610082133 ended
the run with `UnknownError: Expected 'function.name' to be a string.` and no retry.

## Root cause

- `@ai-sdk/openai-compatible` 2.0.81 (bundled) throws `InvalidResponseDataError`
  ("Expected 'function.name' to be a string.") from the provider-utils streaming
  tracker when a stream ends with a pending tool call that never received a name.
- The error is an `AISDKError` (not an `APICallError`), so `MessageV2.fromError`
  fell through to `case e instanceof Error` -> `NamedError.Unknown`, which
  `SessionRetry.retryable` does not retry. The step was not re-requested and the
  run stopped.
- Note: the "name arrives in a LATER delta" variant already works in 2.0.81: the
  provider buffers pending tool calls until the name arrives. Only the
  "name never arrives" variant fails, and it fails at stream end.

## What changed

`packages/opencode/src/session/message-v2.ts` (`fromError`, ~line 709):

- New `case InvalidResponseDataError.isInstance(e)` (before the generic
  `e instanceof Error` fallthrough):
  - Logs one JSON line to stderr:
    `{"event":"openai-compat-invalid-response-data","providerID":...,"message":...,"data":<raw delta>}`
    (`data` is the offending delta object carried on the error, e.g.
    `{"index":0,"id":null,"function":{"arguments":...}}` with no `name`).
  - Returns `SessionV1.APIError` with `isRetryable: true`
    (`metadata.code = "invalid_response_data"`), so `SessionRetry.retryable`
    (`packages/opencode/src/session/retry.ts:71-75`) classifies it retryable and
    the processor (`packages/opencode/src/session/processor.ts:660`) re-requests
    the step with the existing exponential backoff (2s start, 30s cap, no attempt
    cap - same as 5xx handling).
- `InvalidResponseDataError` is imported from `"ai"` (re-export of
  `@ai-sdk/provider`); `.isInstance` is marker-based, so it matches across
  bundled/duplicate package copies.

No provider-package or node_modules changes; the fix lives entirely in OpenCode's
stream-consumer error mapping, so it works for the bundled
`@ai-sdk/openai-compatible` path used by `"npm": "@ai-sdk/openai-compatible"`
provider config.

## Test: `script/jj/missing-tool-call-name/`

- `fake_server.py`: fake OpenAI-compatible server on 127.0.0.1. Request 1
  (no tools) answers "fake title" (title generation is streamed too). First
  tool-bearing request streams a well-formed named bash tool call. First
  request carrying a tool result:
  - MODE `missing`: text part, then a tool-call delta with no `function.name`,
    then the stream closes with no finish reason (the incident shape). Next
    such request streams clean `FAKE-DONE`.
  - MODE `late`: same start, but the name arrives in a later delta; next
    request streams `FAKE-DONE`.
- `run.sh BINARY LABEL MODE [PORT]`: runs `opencode run` in a temp
  HOME/XDG tree (`env -i`, fake provider pointed at the fake server) and prints
  rc, streamed request count, name-error lines, raw-delta log lines, tool
  marker count, and final-text presence.

Builds: `bun run script/build.ts --single --skip-install --skip-embed-web-ui`
from `packages/opencode` (stock = clean tree; fork = with the fix).

### Results (verbatim `run.sh` output; stock = clean tree, fork = with fix)

```
########## STOCK + missing ##########
stock rc=1 mode=missing
  streamed requests: 3
  name error lines: 1
  raw delta log lines: 0
  tool ran: 2
  final text: 0

########## STOCK + late ##########
stock rc=0 mode=late
  streamed requests: 4
  name error lines: 0
  raw delta log lines: 0
  tool ran: 4
  final text: 1

########## FORK + missing ##########
fork rc=0 mode=missing
  streamed requests: 4
  name error lines: 1
  raw delta log lines: 1
  tool ran: 3
  final text: 1

########## FORK + late ##########
fork rc=0 mode=late
  streamed requests: 4
  name error lines: 0
  raw delta log lines: 0
  tool ran: 4
  final text: 1
```

Reading: the pass/fail signals are rc, FAKE-DONE (final text), and raw-delta log
lines. `tool ran` counts `FAKE-TOOL-RAN` occurrences in the combined TUI
stdout+stderr, so it includes the echoed command line (hence 2x the actual tool
executions in some runs) - treat it as a display marker, not an execution count.

- Stock `missing` (bug repro): run ends rc=1 with stderr tail
  `Error: Expected 'function.name' to be a string.` - the incident failure, no
  retry (only 3 streamed requests: title, step-1 tool call, then the broken
  step-2 stream that terminates the run).
- Fork `missing` (fixed): rc=0, 4 streamed requests (the broken step-2 stream is
  retried and the re-request returns clean `FAKE-DONE`). Exactly one raw-delta
  JSON line on stderr:

```json
{"event":"openai-compat-invalid-response-data","providerID":"fake","message":"Expected 'function.name' to be a string.","data":{"index":0,"id":null,"function":{"arguments":"{\"command\": \"echo FAKE-TOOL-RAN\", \"description\": \"Print a marker\"}"}}}
```

- `late` mode passes on both stock and fork (no regression): when the name arrives
  in a later delta, 2.0.81's tracker already buffers and completes the tool call.

Verification: `bun run typecheck` (tsgo, clean) and
`bun test test/session/message-v2.test.ts test/session/retry.test.ts`
(69 pass / 0 fail) in `packages/opencode`.

## sglang #35542

sgl-project/sglang PR #35542 ("Fix: omit null id/name in streaming tool call
deltas", open, unmerged, CI red as of 2026-10-09) is the server-side sibling of
this bug: SGLang serializes continuation tool-call deltas with explicit
`"id":null` / `"function":{"name":null}`, and OpenAI-SDK-style delta mergers
(`x !== undefined`) clobber the name streamed in the first chunk, producing
`unknown tool ""`. That PR omits unset fields instead (`exclude_unset=True`,
matching vLLM). It covers the explicit-null continuation-delta shape, NOT the
incident shape (first delta without a name at all, stream ending with no finish
reason), so the OpenCode-side retry+log is still needed. It also cites
anomalyco/opencode#26412 (vLLM nulls) - same client-side clobber family.

## Recommendations

- Consider a retry attempt cap for provider-side errors (or at least a
  max-attempts notice) so a persistently broken provider can't loop forever at
  30s backoff; current 5xx handling has no cap either.
- Consider upstreaming the OpenAI-SDK `InvalidResponseDataError`
  retryability to the AI SDK / provider packages so all consumers benefit.
- Track/subscribe to sglang PR #35542; once merged and deployed the server-side
  null-omission removes the clobber case, but OpenCode should keep the retry.
- Keep the stderr JSON line unauthenticated-safe: it only echoes request-side
  delta data, never auth headers.

Review: not yet run.
