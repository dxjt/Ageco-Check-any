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
    [[ "$output" == *"用法"* ]]
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
    [[ "$output" == *"没有找到 token"* ]]
}

@test "run-all.sh parses single token from env" {
    export ANYROUTER_TOKENS="sk-ant-testAAA"
    run timeout 5 bash scripts/run-all.sh 2>&1 || true
    [ "$status" -eq 124 ] || true  # 124 = timeout, which is expected
    [[ "$output" == *"已加载 1 个 token"* ]]
}

@test "run-all.sh parses multiple tokens from env" {
    export ANYROUTER_TOKENS="sk-ant-testAAA
sk-ant-testBBB
sk-ant-testCCC"
    run timeout 5 bash scripts/run-all.sh 2>&1 || true
    [[ "$output" == *"已加载 3 个 token"* ]]
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
    [[ "$output" == *"模型: gpt-6-astra"* ]]
    [[ "$output" == *"协议: responses"* ]]
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
    [[ "$output" == *"协议: responses"* ]]
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
    [[ "$output" == *"协议: openai"* ]]
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
    [[ "$output" == *"中转站报错: invalid model"* ]]
}

@test "keepalive.sh rejects an unknown PROTOCOL value" {
    run env PROTOCOL=bogus bash scripts/keepalive.sh "$TEST_TOKEN" "https://anyrouter.top"
    [ "$status" -eq 1 ]
    [[ "$output" == *"未知的 PROTOCOL"* ]]
}

@test "keepalive.sh surfaces the relay error for an unsupported model" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"error":"当前 API 不支持所选模型 gpt-6-astra","type":"error"}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    run bash scripts/keepalive.sh "$TEST_TOKEN" "https://anyrouter.top/v1" "gpt-6-astra"
    [ "$status" -eq 1 ]
    [[ "$output" == *"中转站报错"* ]]
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
    [[ "$output" == *"提示词池: "*"scripts/prompts.txt"* ]]

    # Compare the prompt echoed in the log against the pool: a pool line may
    # itself contain quotes (只输出 JSON：{"status":"ok"}), so pulling it out of
    # the JSON body is unreliable.
    local sent
    sent=$(printf '%s\n' "$output" | sed -n 's/^  提示词: //p' | head -1)
    [ -n "$sent" ]
    case "$sent" in
        *...) sent="${sent%...}" ;;   # the log truncates long prompts to 60 chars
    esac
    grep -Fq "$sent" scripts/prompts.txt
    ! grep -q '"input":""' "$TEST_DIR/curl_args.txt"
    grep -q '"input":"' "$TEST_DIR/curl_args.txt"
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
    [[ "$output" == *"提示词池: $repo_root/scripts/prompts-engineering.txt"* ]]
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
    [[ "$output" == *"请求间隔: 1s"* ]]
    [[ "$output" == *"等待 1s ..."* ]]
    [[ "$output" == *"第 1 轮汇总: 成功 2，失败 0"* ]]
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
    [[ "$output" != *"请求间隔:"* ]]
    [[ "$output" == *"第 1 轮汇总: 成功 2，失败 0"* ]]
}

@test "run-all.sh rejects a non-numeric REQUEST_INTERVAL_SEC" {
    export ANYROUTER_TOKENS="sk-testAAA"
    run env REQUEST_INTERVAL_SEC=abc bash scripts/run-all.sh --once
    [ "$status" -eq 1 ]
    [[ "$output" == *"必须是整数秒"* ]]
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
    [[ "$output" == *"请求间隔: 1s"* ]]
    [[ "$output" == *"等待 1s ..."* ]]
}

@test "keepalive.sh fails fast when the codex CLI is missing" {
    run env PATH="$TEST_DIR/mock_bin:/usr/bin:/bin" PROTOCOL=codex bash scripts/keepalive.sh "$TEST_TOKEN" "https://relay.example.com" "gpt-6-astra"
    [ "$status" -eq 1 ]
    [[ "$output" == *"未找到 codex CLI"* ]]
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
    [[ "$output" == *"协议: codex"* ]]
    [[ "$output" == *"Codex 最终回复"* ]]
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
    [[ "$output" == *"claude CLI 已安装"* ]]
}

@test "install-cli.sh rejects an unknown target" {
    run bash scripts/install-cli.sh bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"用法: "*"claude|codex"* ]]
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
    [[ "$output" == *"FAILED (Codex CLI 报错: We're currently experiencing high demand"* ]]
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
    [[ "$output" == *"FAILED (Claude 报错: 当前模型 claude-opus-4-8[1m] 负载已经达到上限"* ]]
}

@test "keepalive.sh aborts a CLI request on the first Reconnecting retry" {
    cat > "$TEST_DIR/mock_bin/codex" << 'MOCK'
#!/usr/bin/env bash
echo "ERROR: Reconnecting... 1/5"
sleep 20
echo "ERROR: Reconnecting... 5/5"
exit 1
MOCK
    chmod +x "$TEST_DIR/mock_bin/codex"

    SECONDS=0
    run env PROTOCOL=codex TIMEOUT_SEC=15 bash scripts/keepalive.sh "$TEST_TOKEN" "https://anyrouter.top" "gpt-6-astra"
    local elapsed=$SECONDS
    [ "$status" -eq 1 ]
    [[ "$output" == *"检测到重试/错误，已提前结束本次请求"* ]]
    [[ "$output" == *"Reconnecting... 1/5"* ]]
    [[ "$output" != *"Reconnecting... 5/5"* ]]
    [ "$elapsed" -lt 10 ]
}

@test "keepalive.sh can turn the retry abort off with an empty CLI_RETRY_ABORT_PATTERN" {
    cat > "$TEST_DIR/mock_bin/codex" << 'MOCK'
#!/usr/bin/env bash
echo "ERROR: Reconnecting... 1/5"
exit 1
MOCK
    chmod +x "$TEST_DIR/mock_bin/codex"

    run env PROTOCOL=codex CLI_RETRY_ABORT_PATTERN= bash scripts/keepalive.sh "$TEST_TOKEN" "https://anyrouter.top" "gpt-6-astra"
    [ "$status" -eq 1 ]
    [[ "$output" != *"已提前中止"* ]]
    [[ "$output" == *"FAILED (Codex CLI 报错: Reconnecting... 1/5"* ]]
}

@test "run-all.sh never stops on its own when MAX_DURATION_SEC=0" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"id":"resp_forever","object":"response","status":"completed","output_text":"ok"}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    export ANYROUTER_TOKENS="sk-testAAA"
    run timeout 6 env REQUEST_INTERVAL_SEC=1 MAX_DURATION_SEC=0 bash scripts/run-all.sh
    [ "$status" -eq 124 ]   # still looping when timeout killed it
    [[ "$output" == *"剩余: 无限"* ]]
    [[ "$output" != *"达到时间上限"* ]]
    [[ "$output" != *"全部轮次完成"* ]]
}

@test "run-all.sh still stops when MAX_DURATION_SEC is set" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"id":"resp_limited","object":"response","status":"completed","output_text":"ok"}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    export ANYROUTER_TOKENS="sk-testAAA"
    run env REQUEST_INTERVAL_SEC=1 MAX_DURATION_SEC=2 bash scripts/run-all.sh
    [ "$status" -eq 0 ]
    [[ "$output" == *"达到时间上限"* ]]
    [[ "$output" != *"剩余: 无限"* ]]
}

@test "monitor-recovery.sh never stops on its own when MAX_DURATION_SEC=0" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"error":{"message":"relay down"}}'
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    export ANYROUTER_TOKENS="sk-testAAA"
    run timeout 6 env REQUEST_INTERVAL_SEC=1 MAX_DURATION_SEC=0 bash scripts/monitor-recovery.sh
    [ "$status" -eq 124 ]
    [[ "$output" == *"剩余: 无限"* ]]
}

@test "continue-workflow.sh skips the re-dispatch outside GitHub Actions" {
    run env -u GH_TOKEN -u GITHUB_TOKEN -u GITHUB_REPOSITORY bash scripts/continue-workflow.sh keepalive.yml
    [ "$status" -eq 0 ]
    [[ "$output" == *"跳过续跑"* ]]
}

@test "continue-workflow.sh re-dispatches the workflow with the same inputs" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_DIR/curl_args.txt"
exit 0
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    run env GH_TOKEN=faketoken GITHUB_REPOSITORY=owner/repo GITHUB_REF_NAME=main \
        WORKFLOW_INPUTS_JSON='{"model":"gpt-6-astra","auto_continue":"true"}' \
        bash scripts/continue-workflow.sh keepalive.yml
    [ "$status" -eq 0 ]
    grep -q 'actions/workflows/keepalive.yml/dispatches' "$TEST_DIR/curl_args.txt"
    grep -q '"ref":"main"' "$TEST_DIR/curl_args.txt"
    grep -q 'auto_continue' "$TEST_DIR/curl_args.txt"
    [[ "$output" == *"已触发下一段运行"* ]]
}

@test "keepalive.sh retries with the [1m] model when the relay asks for 1m context" {
    cat > "$TEST_DIR/mock_bin/claude" << 'MOCK'
#!/usr/bin/env bash
model=""
while [ $# -gt 0 ]; do
    if [ "$1" = "--model" ]; then model="$2"; fi
    shift
done
printf 'model=%s\n' "$model" >> "$TEST_DIR/claude_models.txt"
case "$model" in
    *'[1m]') echo "Mock claude: healthy"; exit 0 ;;
esac
echo 'API Error: 400 {"error":"1m 上下文已经全量可用，请启用 1m 上下文后重试","type":"error"}'
sleep 30
exit 1
MOCK
    chmod +x "$TEST_DIR/mock_bin/claude"

    SECONDS=0
    run bash scripts/keepalive.sh "$TEST_TOKEN" "https://anyrouter.top" "claude-fable-5-1"
    local elapsed=$SECONDS
    [ "$elapsed" -lt 10 ]
    [ "$status" -eq 0 ]
    [[ "$output" == *"自动改用 claude-fable-5-1[1m] 重试"* ]]
    [[ "$output" == *"协议: anthropic | 模型: claude-fable-5-1[1m]"* ]]
    [[ "$output" == *"SUCCESS"* ]]
    grep -q '^model=claude-fable-5-1$' "$TEST_DIR/claude_models.txt"
    grep -q '^model=claude-fable-5-1\[1m\]$' "$TEST_DIR/claude_models.txt"
}

@test "keepalive.sh surfaces the 1m-context error when the model already has the [1m] suffix" {
    cat > "$TEST_DIR/mock_bin/claude" << 'MOCK'
#!/usr/bin/env bash
echo 'API Error: 400 {"error":"1m 上下文已经全量可用，请启用 1m 上下文后重试","type":"error"}'
exit 1
MOCK
    chmod +x "$TEST_DIR/mock_bin/claude"

    run bash scripts/keepalive.sh "$TEST_TOKEN" "https://anyrouter.top" "claude-fable-5-1[1m]"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED (Claude 报错: 1m 上下文已经全量可用，请启用 1m 上下文后重试)"* ]]
    [[ "$output" != *"自动改用"* ]]
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
    [[ "$output" == *"首次成功后降速: 1 分钟保活节奏"* ]]
    [[ "$output" == *">>> 首次收到正常回复 - 降速到 1 分钟保活节奏"* ]]
    [[ "$output" == *"休眠 60s，等待第 2 轮"* ]]
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
    [[ "$output" == *">>> 首次收到正常回复: 已切换到 1 分钟保活节奏"* ]]
    [[ "$output" == *"第 1 轮汇总: 成功 2，失败 0"* ]]
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
    [[ "$output" == *"首次成功后降速: 已禁用"* ]]
    [[ "$output" != *"降速到"* ]]
    [[ "$output" == *"休眠 1s，等待第 2 轮"* ]]
}

@test "run-all.sh rejects a non-numeric SLOW_INTERVAL_MIN" {
    export ANYROUTER_TOKENS="sk-testAAA"
    run env REQUEST_INTERVAL_SEC=1 SLOW_INTERVAL_MIN=soon bash scripts/run-all.sh --once
    [ "$status" -eq 1 ]
    [[ "$output" == *"SLOW_INTERVAL_MIN 必须是整数分钟"* ]]
}

@test "run-all.sh can print the raw SMTP conversation when SMTP_DEBUG=true" {
    cat > "$TEST_DIR/mock_bin/curl" << 'MOCK'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
    echo "curl 8.5.0 (x86_64) libcurl/8.5.0 OpenSSL zlib ... smtp"
    exit 0
fi
echo "mock curl: $*" >&2
exit 55
MOCK
    chmod +x "$TEST_DIR/mock_bin/curl"

    export ANYROUTER_TOKENS="sk-testAAA"
    run env QQ_EMAIL="someone@qq.com" QQ_SMTP_AUTH_CODE="fakecode" SMTP_DEBUG=true bash scripts/run-all.sh --once
    [[ "$output" == *"SMTP_DEBUG: 打印原始 SMTP 会话"* ]]
    [[ "$output" == *"邮件发送 FAILED (curl 退出码: 55)"* ]]
}
