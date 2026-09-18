#!/usr/bin/env bash
# keepalive.sh - Health-check a single Anyrouter token
# Usage: keepalive.sh <token> [base_url] [model]
#
# Protocol selection (PROTOCOL env var):
#   auto (default) - model ids starting with "claude" use the Anthropic Messages
#                    API through the Claude Code CLI; any other model id uses
#                    the OpenAI Responses API at /v1/responses
#   anthropic      - force Claude Code CLI (Anthropic Messages API)
#   responses      - force the OpenAI Responses API at /v1/responses
#   openai         - force the legacy chat-completions API at /v1/chat/completions
#   codex          - drive the OpenAI Codex CLI (codex exec) with a throwaway
#                    CODEX_HOME pointing at BASE_URL
#
# Other env vars: MAX_TOKENS (default 128, "none" to omit the field),
#                 TIMEOUT_SEC (default 120),
#                 PROMPTS_FILE (default scripts/prompts.txt; each request picks a
#                               random line from it. A relative path is resolved
#                               against the repo root, then the cwd)
#
# Prints ALL output (including errors, retries, stack traces) for diagnostics.
set -euo pipefail

TOKEN="${1:?用法: $0 <token> [base_url] [model]}"
BASE_URL="${2:-https://anyrouter.top}"
MODEL="${3:-gpt-6-astra}"
PROTOCOL="${PROTOCOL:-auto}"
MAX_TOKENS="${MAX_TOKENS:-128}"
TIMEOUT_SEC="${TIMEOUT_SEC:-120}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_FILE="${PROMPTS_FILE:-$SCRIPT_DIR/prompts.txt}"
# Resolve a relative PROMPTS_FILE against the repo root first, then the cwd, so
# both "scripts/prompts-engineering.txt" and "./my-prompts.txt" work.
if [ ! -f "$PROMPTS_FILE" ] && [ "${PROMPTS_FILE#/}" = "$PROMPTS_FILE" ]; then
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    if [ -f "$REPO_ROOT/$PROMPTS_FILE" ]; then
        PROMPTS_FILE="$REPO_ROOT/$PROMPTS_FILE"
    fi
fi

# --- Resolve protocol (explicit PROTOCOL wins, otherwise infer from model id) ---
if [ "$PROTOCOL" = "auto" ]; then
    case "$MODEL" in
        claude*) PROTOCOL="anthropic" ;;
        *)       PROTOCOL="responses" ;;
    esac
fi
case "$PROTOCOL" in
    anthropic|responses|openai|codex) ;;
    *)
        echo "  FAILED (未知的 PROTOCOL 值 '$PROTOCOL'，可选 auto|anthropic|responses|openai|codex)" >&2
        exit 1
        ;;
esac

# The two CLI-driven protocols need their CLI on PATH before we can run anything
case "$PROTOCOL" in
    anthropic)
        if ! command -v claude >/dev/null 2>&1; then
            echo "  FAILED (未找到 claude CLI - 请先运行 'bash scripts/install-cli.sh claude'，或设置 install_cli=yes)" >&2
            exit 1
        fi
        ;;
    codex)
        if ! command -v codex >/dev/null 2>&1; then
            echo "  FAILED (未找到 codex CLI - 请先运行 'bash scripts/install-cli.sh codex'，或设置 install_cli=yes)" >&2
            exit 1
        fi
        ;;
esac

# Pick a random non-empty, non-comment prompt line
pick_prompt() {
    if [ -f "$PROMPTS_FILE" ]; then
        local prompts=()
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            prompts+=("$line")
        done < "$PROMPTS_FILE"
        if [ ${#prompts[@]} -gt 0 ]; then
            echo "${prompts[$((RANDOM % ${#prompts[@]}))]}"
            return
        fi
    fi
    echo "Write a one-line Python function to check if a string is a palindrome."
}

# --- OpenAI-compatible helpers ---
# Build the endpoint URL from BASE_URL for a given path ("responses" or
# "chat/completions"). Accepts https://host, https://host/, https://host/v1
# or an already complete endpoint URL.
api_endpoint() {
    local base="${1%/}" path="$2"
    case "$base" in
        */"$path") printf '%s' "$base" ;;
        */v1)      printf '%s/%s' "$base" "$path" ;;
        *)         printf '%s/v1/%s' "$base" "$path" ;;
    esac
}

# Base URL in the ".../v1" form the CLIs expect in their config files
openai_base_url() {
    local base="${1%/}"
    case "$base" in
        */v1)        printf '%s' "$base" ;;
        */responses) printf '%s' "${base%/responses}" ;;
        *)           printf '%s/v1' "$base" ;;
    esac
}

# Minimal JSON string escaping (backslash, double quote, control characters)
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\r'/}"
    s="${s//$'\n'/ }"
    s="${s//$'\t'/ }"
    printf '%s' "$s"
}

# Build the chat-completions request body (jq when available, manual escaping otherwise)
build_chat_body() {
    if command -v jq >/dev/null 2>&1; then
        if [ "$MAX_TOKENS" = "none" ]; then
            jq -nc --arg model "$MODEL" --arg prompt "$PROMPT" \
                '{model:$model, messages:[{role:"user", content:$prompt}], stream:false}'
        else
            jq -nc --arg model "$MODEL" --arg prompt "$PROMPT" --argjson max "$MAX_TOKENS" \
                '{model:$model, messages:[{role:"user", content:$prompt}], max_tokens:$max, stream:false}'
        fi
    elif [ "$MAX_TOKENS" = "none" ]; then
        printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"stream":false}' \
            "$(json_escape "$MODEL")" "$(json_escape "$PROMPT")"
    else
        printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":%s,"stream":false}' \
            "$(json_escape "$MODEL")" "$(json_escape "$PROMPT")" "$MAX_TOKENS"
    fi
}

# Build the Responses API request body (jq when available, manual escaping otherwise)
build_responses_body() {
    if command -v jq >/dev/null 2>&1; then
        if [ "$MAX_TOKENS" = "none" ]; then
            jq -nc --arg model "$MODEL" --arg input "$PROMPT" \
                '{model:$model, input:$input, stream:false}'
        else
            jq -nc --arg model "$MODEL" --arg input "$PROMPT" --argjson max "$MAX_TOKENS" \
                '{model:$model, input:$input, max_output_tokens:$max, stream:false}'
        fi
    elif [ "$MAX_TOKENS" = "none" ]; then
        printf '{"model":"%s","input":"%s","stream":false}' \
            "$(json_escape "$MODEL")" "$(json_escape "$PROMPT")"
    else
        printf '{"model":"%s","input":"%s","max_output_tokens":%s,"stream":false}' \
            "$(json_escape "$MODEL")" "$(json_escape "$PROMPT")" "$MAX_TOKENS"
    fi
}

# Extract the assistant text from an OpenAI-style response (best effort without jq).
# Responses API: output_text, or output[].content[].text
# Chat Completions: choices[0].message.content
extract_openai_content() {
    local body="$1"
    if command -v jq >/dev/null 2>&1; then
        if [ "$PROTOCOL" = "responses" ]; then
            printf '%s' "$body" | jq -r '
                if (.output_text // "") != "" then .output_text
                else ([.output[]? | select(.type == "message") | .content[]?
                       | select(.type == "output_text") | .text] | join(" "))
                end' 2>/dev/null || true
        else
            printf '%s' "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true
        fi
    elif printf '%s' "$body" | grep -qE '"output_text"|"type":"message"|"choices"'; then
        printf '%s' "$body"
    fi
    return 0
}

# Extract the error text from an OpenAI-style error payload (best effort)
extract_error_message() {
    local body="$1"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$body" | jq -r 'if (.error | type) == "string" then .error else (.error.message // empty) end' 2>/dev/null || true
    else
        printf '%s' "$body" | tr ',' '\n' \
            | sed -n -e 's/.*"message":"\([^"]*\)".*/\1/p' -e 's/.*"error":"\([^"]*\)".*/\1/p'
    fi
    return 0
}

# Pull the relay/provider message out of a CLI log: codex prints "ERROR: ..."
# lines, claude prints "Error: ..." or a {"error": ...} blob.
extract_cli_error() {
    local log="$1" line
    [ -f "$log" ] || return 0
    line=$(grep -aE '^[[:space:]]*(ERROR|Error)' "$log" 2>/dev/null | tail -1 || true)
    case "$line" in
        *'"message":"'*)
            line=$(printf '%s' "$line" | sed -e 's/.*"message":"\([^"]*\)".*/\1/')
            ;;
        *'"error":"'*)
            line=$(printf '%s' "$line" | sed -e 's/.*"error":"\([^"]*\)".*/\1/')
            ;;
        *)
            line=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/^ERROR:[[:space:]]*//' -e 's/^Error:[[:space:]]*//')
            ;;
    esac
    printf '%s' "$line"
    return 0
}

PROMPT=$(pick_prompt)

# --- Run health check ---
OUTPUT_FILE=$(mktemp)
EXIT_CODE=0
SETTINGS_FILE=""
LAST_MSG_FILE=""
CODEX_HOME_DIR=""
CODEX_WORK_DIR=""
API_LABEL="Claude"

if [ "$PROTOCOL" = "codex" ]; then
    # Codex CLI path: a throwaway CODEX_HOME carries the relay endpoint, so the
    # caller's own ~/.codex/config.toml is never touched.
    API_LABEL="Codex CLI"
    # Keep CODEX_HOME out of /tmp: codex refuses to create its PATH aliases there
    CODEX_HOME_DIR=$(mktemp -d "$HOME/.codex-keepalive.XXXXXX")
    CODEX_WORK_DIR=$(mktemp -d)
    LAST_MSG_FILE="$CODEX_WORK_DIR/last_message.txt"
    cat > "$CODEX_HOME_DIR/config.toml" << EOF
model = "$MODEL"
model_provider = "anyrouter"
approval_policy = "never"
sandbox_mode = "read-only"

[model_providers.anyrouter]
name = "Anyrouter"
base_url = "$(openai_base_url "$BASE_URL")"
env_key = "ANYROUTER_API_KEY"
wire_api = "responses"
EOF
    export ANYROUTER_API_KEY="$TOKEN"
    timeout "$TIMEOUT_SEC" env CODEX_HOME="$CODEX_HOME_DIR" \
        codex exec --model "$MODEL" --skip-git-repo-check --ephemeral \
        -C "$CODEX_WORK_DIR" -o "$LAST_MSG_FILE" "$PROMPT" < /dev/null > "$OUTPUT_FILE" 2>&1 || EXIT_CODE=$?
elif [ "$PROTOCOL" != "anthropic" ]; then
    # OpenAI-compatible path: direct HTTP call to /v1/responses or /v1/chat/completions
    if [ "$PROTOCOL" = "responses" ]; then
        API_LABEL="OpenAI Responses"
        REQUEST_BODY=$(build_responses_body)
        API_URL=$(api_endpoint "$BASE_URL" "responses")
    else
        API_LABEL="OpenAI Chat"
        REQUEST_BODY=$(build_chat_body)
        API_URL=$(api_endpoint "$BASE_URL" "chat/completions")
    fi
    curl -sS --max-time "$TIMEOUT_SEC" -X POST "$API_URL" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$REQUEST_BODY" > "$OUTPUT_FILE" 2>&1 || EXIT_CODE=$?
else
    # Anthropic path: Claude Code CLI reads token/base_url from settings.json
    SETTINGS_DIR="$HOME/.claude"
    SETTINGS_FILE="$SETTINGS_DIR/settings.json"
    TMP_FILE="$SETTINGS_DIR/settings.json.tmp.$$.$(date +%s%N)"

    mkdir -p "$SETTINGS_DIR"

    cat > "$TMP_FILE" << EOF
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "$TOKEN",
    "ANTHROPIC_BASE_URL": "$BASE_URL"
  }
}
EOF
    mv "$TMP_FILE" "$SETTINGS_FILE"

    EXTRA_FLAGS=()
    if [ "${CI:-}" = "true" ]; then
        EXTRA_FLAGS+=(--dangerously-skip-permissions)
    fi

    # Run claude with timeout to prevent infinite retry hangs.
    timeout "$TIMEOUT_SEC" claude -p "$PROMPT" --print --model "$MODEL" --bare "${EXTRA_FLAGS[@]}" > "$OUTPUT_FILE" 2>&1 || EXIT_CODE=$?
fi

# --- Print ALL output for diagnostics ---
echo "  协议: ${PROTOCOL} | 模型: ${MODEL}"
echo "  提示词池: ${PROMPTS_FILE}"
echo "  提示词: ${PROMPT:0:60}..."
echo "  --- ${API_LABEL} 输出 (exit_code=$EXIT_CODE) ---"
cat "$OUTPUT_FILE" | sed 's/^/    /'
echo "  --- 输出结束 ---"

CLI_ERROR=""
if [ "$PROTOCOL" = "anthropic" ] || [ "$PROTOCOL" = "codex" ]; then
    CLI_ERROR=$(extract_cli_error "$OUTPUT_FILE")
fi

if [ -n "$LAST_MSG_FILE" ] && [ -s "$LAST_MSG_FILE" ]; then
    echo "  --- Codex 最终回复 ---"
    sed 's/^/    /' "$LAST_MSG_FILE"
    echo "  --- 最终回复结束 ---"
fi

# --- Evaluate result ---
OUTPUT_CONTENT=$(cat "$OUTPUT_FILE" 2>/dev/null || true)

# The CLI protocols talk to the model through their own runtime, so the file the
# CLI wrote is the authoritative answer (the log above is just diagnostics).
if [ -n "$LAST_MSG_FILE" ] && [ -s "$LAST_MSG_FILE" ]; then
    OUTPUT_CONTENT=$(cat "$LAST_MSG_FILE")
fi

# Clean up. Never let a locked/busy temp file abort the health check: on Windows
# the codex process may still hold a handle when we get here.
rm -f "$OUTPUT_FILE" "$SETTINGS_FILE" 2>/dev/null || true
if [ -n "$LAST_MSG_FILE" ]; then
    rm -f "$LAST_MSG_FILE" 2>/dev/null || true
fi
if [ -n "$CODEX_HOME_DIR" ]; then
    rm -rf "$CODEX_HOME_DIR" 2>/dev/null || true
fi
if [ -n "$CODEX_WORK_DIR" ]; then
    rm -rf "$CODEX_WORK_DIR" 2>/dev/null || true
fi

# 1. Non-zero exit code is a clear failure (includes timeout exit 124)
if [ "$EXIT_CODE" -ne 0 ]; then
    if [ -n "$CLI_ERROR" ]; then
        echo "  FAILED (${API_LABEL} 报错: ${CLI_ERROR})"
    elif [ "$EXIT_CODE" -eq 124 ]; then
        echo "  FAILED (超时 ${TIMEOUT_SEC}s)"
    else
        echo "  FAILED (退出码非零: $EXIT_CODE)"
    fi
    exit 1
fi

# 2. Empty response is a failure
if [ -z "$OUTPUT_CONTENT" ]; then
    echo "  FAILED (响应内容为空)"
    exit 1
fi

# 3. curl-based paths: the body must carry assistant content (the CLI protocols
#    are judged by the answer file the CLI wrote instead)
if [ "$PROTOCOL" = "responses" ] || [ "$PROTOCOL" = "openai" ]; then
    if [ -z "$(extract_openai_content "$OUTPUT_CONTENT")" ]; then
        RELAY_ERROR=$(extract_error_message "$OUTPUT_CONTENT")
        if [ -n "$RELAY_ERROR" ]; then
            echo "  FAILED (中转站报错: $RELAY_ERROR)"
        else
            echo "  FAILED (OpenAI 响应里没有 assistant 内容)"
        fi
        exit 1
    fi
fi

echo "  SUCCESS"
exit 0
