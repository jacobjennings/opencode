#!/bin/bash
# usage: run.sh OPENCODE_BINARY LABEL MODE -> runs one opencode turn against the fake server
# in a fully temporary HOME/XDG/TMP tree under /tmp/jake-harness-workers (never in the
# worktree), prints the exit code and the markers seen, and exits non-zero when the
# run's expected markers for the mode are missing.
# MODE: missing (name never arrives) | late (name arrives in a later delta)
set -u
bin=$(readlink -f "$1"); label=$2; mode=${3:-missing}; port=${4:-18932}
here=$(cd "$(dirname "$0")" && pwd)

base=/tmp/jake-harness-workers
mkdir -p "$base"
work=$(mktemp -d "$base/run-$label-XXXXXX")
mkdir -p "$work/home" "$work/tmp" "$work/xdg/config/opencode" "$work/xdg/data" "$work/xdg/cache" "$work/xdg/state" "$work/proj"
cat > "$work/xdg/config/opencode/opencode.json" <<EOF
{"\$schema":"https://opencode.ai/config.json","autoupdate":false,"share":"disabled",
 "model":"fake/fake-model","small_model":"fake/fake-model",
 "permission":{"bash":"allow","edit":"allow"},
 "provider":{"fake":{"npm":"@ai-sdk/openai-compatible","name":"fake",
     "options":{"baseURL":"http://127.0.0.1:$port/v1","apiKey":"x"},
     "models":{"fake-model":{"name":"fake-model","tool_call":true}}}}}
EOF
python3 -I "$here/fake_server.py" "$port" "$work" "$mode" & srv=$!
sleep 1
( cd "$work/proj" && git init -q . && env -i PATH=/usr/bin:/bin HOME="$work/home" \
  TMPDIR="$work/tmp" \
  XDG_CONFIG_HOME="$work/xdg/config" XDG_DATA_HOME="$work/xdg/data" XDG_CACHE_HOME="$work/xdg/cache" \
  XDG_STATE_HOME="$work/xdg/state" OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 \
  CUDA_VISIBLE_DEVICES= NVIDIA_VISIBLE_DEVICES=void \
  timeout 120 "$bin" run --model fake/fake-model "run the marker command" < /dev/null > "$work/out.txt" 2> "$work/err.txt" )
rc=$?
kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
echo "$label rc=$rc mode=$mode work=$work"
streamed=$(grep -c '"stream": *true\|"stream":true' "$work/requests.jsonl" 2>/dev/null); streamed=${streamed:-0}
nameerr=$(cat "$work/out.txt" "$work/err.txt" | grep -c "Expected 'function.name' to be a string"); nameerr=${nameerr:-0}
rawlog=$(cat "$work/out.txt" "$work/err.txt" | grep -c 'openai-compat-invalid-response-data'); rawlog=${rawlog:-0}
toolar=$(cat "$work/out.txt" "$work/err.txt" | grep -c 'FAKE-TOOL-RAN'); toolar=${toolar:-0}
done=$(grep -c 'FAKE-DONE' "$work/out.txt" 2>/dev/null); done=${done:-0}
echo "  streamed requests: $streamed"
echo "  name error lines: $nameerr"
echo "  raw delta log lines: $rawlog"
echo "  tool ran: $toolar"
echo "  final text: $done"
fail=0
check() { # check <what> <count> <min>
  if [ "$2" -lt "$3" ]; then echo "  FAIL: $what (got $2, expected >= $3)"; fail=1; fi
}
check "fake server was hit" "$streamed" 1
if [ "$mode" = "missing" ]; then
  check "incident reproduced (missing name)" "$nameerr" 1
  check "recovered to clean text" "$done" 1
else
  check "tool eventually ran (late name)" "$toolar" 1
  check "completed cleanly" "$done" 1
fi
if [ "$fail" -ne 0 ]; then echo "  RESULT: FAIL (mode=$mode)"; exit 1; fi
echo "  RESULT: OK (mode=$mode)"
exit 0
