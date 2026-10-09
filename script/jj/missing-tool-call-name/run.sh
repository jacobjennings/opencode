#!/bin/bash
# usage: run.sh LABEL MODE [PORT]
# Runs one opencode turn against the fake server, building/running opencode from THIS
# branch (via its source entrypoint), inside a fresh scratch tree under
# /tmp/jake-harness-workers. It never uses the worktree, the installed binary, or the
# real $HOME, and it never touches ~/.cache. Exits nonzero when the mode's expected
# markers are missing, or when opencode did not write its database into the scratch tree.
# MODE: missing (name never arrives) | late (name arrives in a later delta)
#       | retry-text (first attempt emits fixed text + a no-name tool call, retry is clean)
set -u
here=$(cd "$(dirname "$0")" && pwd)
repoRoot=$(cd "$here/../../.." && pwd)
cliEntry="$repoRoot/packages/opencode/src/index.ts"

label=${1:-smoke}; mode=${2:-missing}; port=${3:-18932}

BUN=$(command -v bun || true)
if [ -z "$BUN" ]; then echo "bun not found on PATH; cannot run the branch source"; exit 2; fi
if [ ! -f "$cliEntry" ]; then echo "branch CLI entry not found: $cliEntry"; exit 2; fi

base=/tmp/jake-harness-workers
mkdir -p "$base"
work=$(mktemp -d "$base/run-$label-XXXXXX")
# Fresh scratch tree: HOME + TMPDIR + every XDG_* live under the run's scratch root.
mkdir -p "$work/home" "$work/tmp" "$work/xdg/config/opencode" "$work/xdg/data" "$work/xdg/state" "$work/xdg/cache" "$work/proj"
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
# Isolation: wipe the inherited environment so no inherited XDG_* value leaks in, then
# pin HOME, TMPDIR and all four XDG_* to the scratch tree, OPENCODE_TEST_HOME to pin
# os.homedir(), OPENCODE_DISABLE_PROJECT_CONFIG so the worktree's project config is
# ignored, and the remaining OPENCODE_* flags to stop any background work (autoupdate,
# model fetch, plugin discovery, autocompact) and skip the real auth file. This forces
# every opencode write into the scratch tree.
( cd "$work/proj" && git init -q . && env -i \
    PATH=/usr/bin:/bin \
    HOME="$work/home" TMPDIR="$work/tmp" \
    XDG_CONFIG_HOME="$work/xdg/config" XDG_DATA_HOME="$work/xdg/data" \
    XDG_STATE_HOME="$work/xdg/state" XDG_CACHE_HOME="$work/xdg/cache" \
    OPENCODE_TEST_HOME="$work/home" \
    OPENCODE_DISABLE_PROJECT_CONFIG=1 \
    OPENCODE_PURE=1 \
    OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_DISABLE_AUTOCOMPACT=1 \
    OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_AUTH_CONTENT='{}' \
    CUDA_VISIBLE_DEVICES= NVIDIA_VISIBLE_DEVICES=void \
    timeout 180 "$BUN" run --conditions=browser "$cliEntry" run --model fake/fake-model "run the marker command" < /dev/null > "$work/out.txt" 2> "$work/err.txt" )
rc=$?
kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null

streamed=$(grep -c '"stream": *true\|"stream":true' "$work/requests.jsonl" 2>/dev/null); streamed=${streamed:-0}
nameerr=$(cat "$work/out.txt" "$work/err.txt" | grep -c "Expected 'function.name' to be a string"); nameerr=${nameerr:-0}
rawlog=$(cat "$work/out.txt" "$work/err.txt" | grep -c 'openai-compat-invalid-response-data'); rawlog=${rawlog:-0}
toolar=$(cat "$work/out.txt" "$work/err.txt" | grep -c 'FAKE-TOOL-RAN'); toolar=${toolar:-0}
done=$(grep -c 'FAKE-DONE' "$work/out.txt" 2>/dev/null); done=${done:-0}
out_count=$(grep -c 'RETRY-TEXT-SENTINEL-7Q' "$work/out.txt" 2>/dev/null); out_count=${out_count:-0}
db="$work/xdg/data/opencode/opencode-local.db"

echo "$label rc=$rc mode=$mode work=$work"
echo "  streamed requests: $streamed"
echo "  name error lines: $nameerr"
echo "  raw delta log lines: $rawlog"
echo "  tool ran: $toolar"
echo "  final text: $done"
echo "  run-output sentinel count: $out_count"

fail=0
check() { if [ "$2" -lt "$3" ]; then echo "  FAIL: $1 (got $2, expected >= $3)"; fail=1; fi; }

# 4b: the scratch tree is a fresh mktemp dir, so a database here proves THIS run wrote
# it under the scratch XDG_DATA_HOME (not the shared real-home database).
if [ ! -f "$db" ]; then
  echo "  FAIL: isolation - scratch database not created at $db (OpenCode did not use the scratch XDG_DATA_HOME)"
  fail=1
fi

if [ "$mode" = "retry-text" ]; then
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "  FAIL: sqlite3 not available; cannot verify the persisted session"
    fail=1
  else
    db_count=$(sqlite3 "$db" "SELECT COUNT(*) FROM part WHERE data LIKE '%RETRY-TEXT-SENTINEL-7Q%';" 2>/dev/null)
    db_count=${db_count:-0}
    echo "  persisted-session sentinel count: $db_count"
    if [ "$db_count" -ne 1 ]; then
      echo "  FAIL: retry-text sentinel must appear exactly once in the persisted session (got $db_count)"
      fail=1
    fi
  fi
elif [ "$mode" = "missing" ]; then
  check "fake server was hit" "$streamed" 1
  check "incident reproduced (missing name)" "$nameerr" 1
  check "recovered to clean text" "$done" 1
else
  check "tool eventually ran (late name)" "$toolar" 1
  check "completed cleanly" "$done" 1
fi

if [ "$fail" -ne 0 ]; then echo "  RESULT: FAIL (mode=$mode)"; exit 1; fi
echo "  RESULT: OK (mode=$mode)"
exit 0
