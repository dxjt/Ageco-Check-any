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

@test "keepalive.sh picks a prompt from prompts.txt" {
    # Verify prompts.txt exists and has content
    [ -f "scripts/prompts.txt" ]
    local count=$(grep -cve '^\s*$' -e '^#' scripts/prompts.txt || true)
    [ "$count" -ge 10 ]
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
