setup_file() {
    # Ensure we're in the project root
    cd "$(dirname "$BATS_TEST_FILENAME")/.."
}

setup() {
    export TEST_TOKEN="sk-ant-test12345678"
    export TEST_DIR=$(mktemp -d)
    export HOME="$TEST_DIR"
    export CI="true"

    # Mock claude globally so all tests that call it don't hang
    mkdir -p "$TEST_DIR/mock_bin"
    cat > "$TEST_DIR/mock_bin/claude" << 'MOCK'
#!/usr/bin/env bash
echo "Mock claude: healthy"
exit 0
MOCK
    chmod +x "$TEST_DIR/mock_bin/claude"
    export PATH="$TEST_DIR/mock_bin:$PATH"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "keepalive.sh fails without token" {
    run bash scripts/keepalive.sh
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
}

@test "keepalive.sh creates and cleans up settings.json" {
    run bash scripts/keepalive.sh "$TEST_TOKEN" "https://anyrouter.top/v1" "claude-opus-4-8[1m]"
    # After run, settings.json should be cleaned up
    [ ! -f "$TEST_DIR/.claude/settings.json" ]
}

@test "prompts.txt holds the 20 lightweight probes" {
    [ -f "scripts/prompts.txt" ]
    local count=$(grep -cve '^[[:space:]]*$' -e '^#' scripts/prompts.txt || true)
    [ "$count" -eq 20 ]
    grep -q '只回复一个字符：1' scripts/prompts.txt
    grep -q '###ALIVE###' scripts/prompts.txt
    [ -f "scripts/prompts-engineering.txt" ]
}

@test "run-all.sh fails without tokens" {
    unset ANYROUTER_TOKENS
    run bash scripts/run-all.sh
    [ "$status" -eq 1 ]
    [[ "$output" == *"No tokens"* ]]
}

@test "run-all.sh parses single token from env" {
    export ANYROUTER_TOKENS="sk-ant-testAAA"
    run timeout 5 bash scripts/run-all.sh 2>&1 || true
    [ "$status" -eq 124 ] || true  # 124 = timeout, which is expected
    [[ "$output" == *"Loaded 1 token(s)"* ]]
}

@test "run-all.sh parses multiple tokens from env" {
    export ANYROUTER_TOKENS="sk-ant-testAAA
sk-ant-testBBB
sk-ant-testCCC"
    run timeout 5 bash scripts/run-all.sh 2>&1 || true
    [[ "$output" == *"Loaded 3 token(s)"* ]]
}

@test "prompts.txt has no empty lines used as prompts" {
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [ -n "$line" ]
    done < scripts/prompts.txt
}

@test "settings.json atomic write pattern works" {
    local dir="$TEST_DIR/.claude"
    local file="$dir/settings.json"
    local tmp="$dir/settings.json.tmp.$$.$(date +%s%N)"
    mkdir -p "$dir"
    cat > "$tmp" <<< '{"env":{"ANTHROPIC_AUTH_TOKEN":"test","ANTHROPIC_BASE_URL":"https://test.com/v1"}}'
    mv "$tmp" "$file"
    [ -f "$file" ]
    grep -q "ANTHROPIC_AUTH_TOKEN" "$file"
    rm -f "$file"
}

@test "keepalive.sh defaults to gpt-6-astra on the Responses API" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"id":"resp_default","status":"completed","output_text":"ok"}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    run bash scripts/keepalive.sh "$TEST_TOKEN" "https://relay.example.com"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Model: gpt-6-astra"* ]]
    [[ "$output" == *"Protocol: responses"* ]]
    [[ "$output" == *"SUCCESS"* ]]
}

@test "keepalive.sh posts to /v1/responses with an input field" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$TEST_DIR/curl_args.txt"
echo '{"id":"resp_test","object":"response","status":"completed","output":[{"type":"reasoning","summary":[]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok","annotations":[]}]}]}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    run bash scripts/keepalive.sh "$TEST_TOKEN" "https://relay.example.com" "gpt-6-astra"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Protocol: responses"* ]]
    [[ "$output" == *"SUCCESS"* ]]
    grep -q '/v1/responses' "$TEST_DIR/curl_args.txt"
    grep -q '"input"' "$TEST_DIR/curl_args.txt"
    grep -q '"max_output_tokens"' "$TEST_DIR/curl_args.txt"
}

@test "keepalive.sh accepts a Responses payload that only carries output_text" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"id":"resp_2","object":"response","status":"completed","output_text":"hello"}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    run bash scripts/keepalive.sh "$TEST_TOKEN" "https://relay.example.com" "gpt-6-astra"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SUCCESS"* ]]
}

@test "keepalive.sh forces the chat-completions path when PROTOCOL=openai" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"choices":[{"index":0,"message":{"role":"assistant","content":"ok"}}]}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    run env PROTOCOL=openai bash scripts/keepalive.sh "$TEST_TOKEN" "https://relay.example.com/v1" "claude-opus-4-8[1m]"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Protocol: openai"* ]]
}

@test "keepalive.sh fails when the OpenAI response has no content" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"error":{"message":"invalid model","type":"invalid_request_error"}}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    run bash scripts/keepalive.sh "$TEST_TOKEN" "https://relay.example.com" "gpt-6-astra"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED"* ]]
    [[ "$output" == *"relay error: invalid model"* ]]
}

@test "keepalive.sh rejects an unknown PROTOCOL value" {
    run env PROTOCOL=bogus bash scripts/keepalive.sh "$TEST_TOKEN" "https://anyrouter.top"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown PROTOCOL"* ]]
}

@test "keepalive.sh surfaces the relay error for an unsupported model" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"error":"当前 API 不支持所选模型 gpt-6-astra","type":"error"}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    run bash scripts/keepalive.sh "$TEST_TOKEN" "https://anyrouter.top/v1" "gpt-6-astra"
    [ "$status" -eq 1 ]
    [[ "$output" == *"relay error"* ]]
    [[ "$output" == *"gpt-6-astra"* ]]
}

@test "list-models.sh prints the model ids returned by the relay" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"data":[{"id":"claude-opus-4-8[1m]"},{"id":"gpt-6-astra"}]}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    run bash scripts/list-models.sh "$TEST_TOKEN" "https://anyrouter.top"
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude-opus-4-8[1m]"* ]]
    [[ "$output" == *"gpt-6-astra"* ]]
}

@test "keepalive.sh sends a prompt taken from the default pool" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$TEST_DIR/curl_args.txt"
echo '{"id":"resp_pool","object":"response","status":"completed","output_text":"ok"}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    run bash scripts/keepalive.sh "$TEST_TOKEN" "https://relay.example.com" "gpt-6-astra"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Prompt pool: "*"scripts/prompts.txt"* ]]

    local sent
    sent=$(grep -o '"input":"[^"]*"' "$TEST_DIR/curl_args.txt" | head -1 | sed -e 's/^"input":"//' -e 's/"$//')
    [ -n "$sent" ]
    grep -Fq "$sent" scripts/prompts.txt
}

@test "keepalive.sh honours PROMPTS_FILE" {
    printf '# custom pool\n只输出一个英文句号。\n' > "$TEST_DIR/custom-prompts.txt"
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$TEST_DIR/curl_args.txt"
echo '{"id":"resp_custom","object":"response","status":"completed","output_text":". "}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    run env PROMPTS_FILE="$TEST_DIR/custom-prompts.txt" bash scripts/keepalive.sh "$TEST_TOKEN" "https://relay.example.com" "gpt-6-astra"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$TEST_DIR/custom-prompts.txt"* ]]
    grep -q '只输出一个英文句号。' "$TEST_DIR/curl_args.txt"
}

@test "keepalive.sh resolves a relative PROMPTS_FILE against the repo root" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$TEST_DIR/curl_args.txt"
echo '{"id":"resp_rel","object":"response","status":"completed","output_text":"ok"}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    local repo_root
    repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    cd "$TEST_DIR"
    run env PROMPTS_FILE=scripts/prompts-engineering.txt bash "$repo_root/scripts/keepalive.sh" "$TEST_TOKEN" "https://relay.example.com" "gpt-6-astra"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Prompt pool: $repo_root/scripts/prompts-engineering.txt"* ]]
}

@test "run-all.sh uses a fixed REQUEST_INTERVAL_SEC between requests" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"id":"resp_interval","object":"response","status":"completed","output_text":"ok"}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    export ANYROUTER_TOKENS="sk-testAAA
sk-testBBB"
    run timeout 30 env REQUEST_INTERVAL_SEC=1 bash scripts/run-all.sh --once
    [ "$status" -eq 0 ]
    [[ "$output" == *"Request interval: 1s"* ]]
    [[ "$output" == *"Waiting 1s ..."* ]]
    [[ "$output" == *"Round 1 summary: 2 success, 0 failed"* ]]
}

@test "run-all.sh treats a blank or space-only interval as not set" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"id":"resp_blank","object":"response","status":"completed","output_text":"ok"}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    export ANYROUTER_TOKENS="sk-testAAA
sk-testBBB"
    run env REQUEST_INTERVAL_SEC=" " bash scripts/run-all.sh --once
    [ "$status" -eq 0 ]
    [[ "$output" != *"Request interval:"* ]]
    [[ "$output" == *"Round 1 summary: 2 success, 0 failed"* ]]
}

@test "run-all.sh rejects a non-numeric REQUEST_INTERVAL_SEC" {
    export ANYROUTER_TOKENS="sk-testAAA"
    run env REQUEST_INTERVAL_SEC=abc bash scripts/run-all.sh --once
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be a whole number of seconds"* ]]
}

@test "monitor-recovery.sh uses a fixed REQUEST_INTERVAL_SEC" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"id":"resp_mon","object":"response","status":"completed","output_text":"ok"}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    export ANYROUTER_TOKENS="sk-testAAA
sk-testBBB"
    run timeout 60 env REQUEST_INTERVAL_SEC=1 MAX_DURATION_SEC=30 bash scripts/monitor-recovery.sh
    [ "$status" -eq 0 ]
    [[ "$output" == *"Request interval: 1s"* ]]
    [[ "$output" == *"Waiting 1s ..."* ]]
}

@test "keepalive.sh fails fast when the codex CLI is missing" {
    run env PATH="$TEST_DIR/mock_bin:/usr/bin:/bin" PROTOCOL=codex bash scripts/keepalive.sh "$TEST_TOKEN" "https://relay.example.com" "gpt-6-astra"
    [ "$status" -eq 1 ]
    [[ "$output" == *"codex CLI not found"* ]]
    [[ "$output" == *"install-cli.sh codex"* ]]
}

@test "keepalive.sh drives the codex CLI with a throwaway CODEX_HOME" {
    cat > "$TEST_DIR/mock_bin/codex" << 'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_DIR/codex_args.txt"
printf 'CODEX_HOME=%s\n' "${CODEX_HOME:-unset}" > "$TEST_DIR/codex_env.txt"
printf 'KEY=%s\n' "${ANYROUTER_API_KEY:-unset}" >> "$TEST_DIR/codex_env.txt"
if [ -f "$CODEX_HOME/config.toml" ]; then cp "$CODEX_HOME/config.toml" "$TEST_DIR/codex_config.toml"; fi
out=""
while [ $# -gt 0 ]; do
    if [ "$1" = "-o" ]; then out="$2"; fi
    shift
done
if [ -n "$out" ]; then printf '1' > "$out"; fi
echo "codex mock ran"
exit 0
MOCK
    chmod +x "$TEST_DIR/mock_bin/codex"

    run env PROTOCOL=codex bash scripts/keepalive.sh "$TEST_TOKEN" "https://anyrouter.top/v1" "gpt-6-astra"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Protocol: codex"* ]]
    [[ "$output" == *"Codex last message"* ]]
    [[ "$output" == *"SUCCESS"* ]]

    grep -q '^exec$' "$TEST_DIR/codex_args.txt"
    grep -q -- '--skip-git-repo-check' "$TEST_DIR/codex_args.txt"
    grep -q 'gpt-6-astra' "$TEST_DIR/codex_args.txt"
    grep -q 'base_url = "https://anyrouter.top/v1"' "$TEST_DIR/codex_config.toml"
    grep -q 'wire_api = "responses"' "$TEST_DIR/codex_config.toml"
    grep -q 'env_key = "ANYROUTER_API_KEY"' "$TEST_DIR/codex_config.toml"
    ! grep -q 'disable_response_storage' "$TEST_DIR/codex_config.toml"
    grep -q '^KEY=sk-ant-test12345678$' "$TEST_DIR/codex_env.txt"
    grep -qv 'CODEX_HOME=unset' "$TEST_DIR/codex_env.txt"
}

@test "install-cli.sh skips an already installed CLI" {
    run bash scripts/install-cli.sh claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude CLI already installed"* ]]
}

@test "install-cli.sh rejects an unknown target" {
    run bash scripts/install-cli.sh bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage: "*"claude|codex"* ]]
}

@test "keepalive.sh reports the codex CLI error message on failure" {
    cat > "$TEST_DIR/mock_bin/codex" << 'MOCK'
#!/usr/bin/env bash
echo "ERROR: We're currently experiencing high demand, which may cause temporary errors." >&2
echo "ERROR: We're currently experiencing high demand, which may cause temporary errors." >&2
exit 1
MOCK
    chmod +x "$TEST_DIR/mock_bin/codex"

    run env PROTOCOL=codex bash scripts/keepalive.sh "$TEST_TOKEN" "https://anyrouter.top" "gpt-6-astra"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED (Codex CLI error: We're currently experiencing high demand"* ]]
}

@test "keepalive.sh reports the claude CLI error message on failure" {
    cat > "$TEST_DIR/mock_bin/claude" << 'MOCK'
#!/usr/bin/env bash
echo 'Error: {"error":{"message":"当前模型 claude-opus-4-8[1m] 负载已经达到上限，请稍后重试"}}'
exit 1
MOCK
    chmod +x "$TEST_DIR/mock_bin/claude"

    run bash scripts/keepalive.sh "$TEST_TOKEN" "https://anyrouter.top" "claude-opus-4-8[1m]"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED (Claude error: 当前模型 claude-opus-4-8[1m] 负载已经达到上限"* ]]
}

@test "run-all.sh slows down to the keepalive pace after the first healthy answer" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"id":"resp_ok","object":"response","status":"completed","output_text":"ok"}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    export ANYROUTER_TOKENS="sk-testAAA
sk-testBBB"
    run timeout 25 env REQUEST_INTERVAL_SEC=1 SLOW_INTERVAL_MIN=1 bash scripts/run-all.sh
    [[ "$output" == *"Slow-down after first success: 1min keepalive pace"* ]]
    [[ "$output" == *">>> First healthy answer - slowing down to a 1min keepalive pace"* ]]
    [[ "$output" == *"Sleeping 60s until round 2"* ]]
}

@test "run-all.sh records the slow-down in the report body" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"id":"resp_ok","object":"response","status":"completed","output_text":"ok"}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    export ANYROUTER_TOKENS="sk-testAAA
sk-testBBB"
    run env REQUEST_INTERVAL_SEC=1 SLOW_INTERVAL_MIN=1 MAX_DURATION_SEC=3 bash scripts/run-all.sh
    [ "$status" -eq 0 ]
    [[ "$output" == *">>> First healthy answer: switched to the 1min keepalive pace"* ]]
    [[ "$output" == *"Round 1 summary: 2 success, 0 failed"* ]]
}

@test "run-all.sh keeps the fast pace when the slow-down is disabled" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"id":"resp_ok","object":"response","status":"completed","output_text":"ok"}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    export ANYROUTER_TOKENS="sk-testAAA
sk-testBBB"
    run timeout 25 env REQUEST_INTERVAL_SEC=1 SLOW_INTERVAL_MIN=0 bash scripts/run-all.sh
    [[ "$output" == *"Slow-down after first success: disabled"* ]]
    [[ "$output" != *"slowing down to a"* ]]
    [[ "$output" == *"Sleeping 1s until round 2"* ]]
}

@test "run-all.sh rejects a non-numeric SLOW_INTERVAL_MIN" {
    export ANYROUTER_TOKENS="sk-testAAA"
    run env REQUEST_INTERVAL_SEC=1 SLOW_INTERVAL_MIN=soon bash scripts/run-all.sh --once
    [ "$status" -eq 1 ]
    [[ "$output" == *"SLOW_INTERVAL_MIN must be a whole number of minutes"* ]]
}
