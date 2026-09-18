#!/usr/bin/env bash
# keepalive.sh - Health-check a single Anyrouter token
# Usage: keepalive.sh <token> [base_url] [model]
#
# Protocol selection (PROTOCOL env var):
#   auto (default) - model ids starting with "claude" use the Anthropic Messages
#                    API through the Claude Code CLI; any other model id uses
#                    the OpenAI-compatible /v1/chat/completions endpoint
#   anthropic      - force Claude Code CLI (Anthropic Messages API)
#   openai         - force a direct curl call to /v1/chat/completions
#
# Other env vars: MAX_TOKENS (default 128, "none" to omit the field),
#                 TIMEOUT_SEC (default 120)
#
# Prints ALL output (including errors, retries, stack traces) for diagnostics.
set -euo pipefail

TOKEN="${1:?Usage: $0 <token> [base_url] [model]}"
BASE_URL="${2:-https://anyrouter.top}"
MODEL="${3:-claude-opus-4-8[1m]}"
PROTOCOL="${PROTOCOL:-auto}"
MAX_TOKENS="${MAX_TOKENS:-128}"
TIMEOUT_SEC="${TIMEOUT_SEC:-120}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_FILE="$SCRIPT_DIR/prompts.txt"

# --- Resolve protocol (explicit PROTOCOL wins, otherwise infer from model id) ---
if [ "$PROTOCOL" = "auto" ]; then
    case "$MODEL" in
        claude*) PROTOCOL="anthropic" ;;
        *)       PROTOCOL="openai" ;;
    esac
fi
case "$PROTOCOL" in
    anthropic|openai) ;;
    *)
        echo "  FAILED (unknown PROTOCOL '$PROTOCOL', expected auto|anthropic|openai)" >&2
        exit 1
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
# Build the chat-completions URL from BASE_URL.
# Accepts https://host, https://host/, https://host/v1 or a full endpoint URL.
openai_chat_url() {
    local base="${1%/}"
    case "$base" in
        */chat/completions) printf '%s' "$base" ;;
        */v1)               printf '%s/chat/completions' "$base" ;;
        *)                  printf '%s/v1/chat/completions' "$base" ;;
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

# Extract the assistant text from a chat-completions response (best effort without jq)
extract_chat_content() {
    local body="$1"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true
    elif printf '%s' "$body" | grep -q '"choices"'; then
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

PROMPT=$(pick_prompt)

# --- Run health check ---
OUTPUT_FILE=$(mktemp)
EXIT_CODE=0
SETTINGS_FILE=""
API_LABEL="Claude"

if [ "$PROTOCOL" = "openai" ]; then
    # OpenAI-compatible path: direct HTTP call to /v1/chat/completions
    API_LABEL="OpenAI"
    CHAT_URL=$(openai_chat_url "$BASE_URL")
    REQUEST_BODY=$(build_chat_body)
    curl -sS --max-time "$TIMEOUT_SEC" -X POST "$CHAT_URL" \
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
echo "  Protocol: ${PROTOCOL} | Model: ${MODEL}"
echo "  Prompt: ${PROMPT:0:60}..."
echo "  --- ${API_LABEL} output (exit_code=$EXIT_CODE) ---"
cat "$OUTPUT_FILE" | sed 's/^/    /'
echo "  --- End output ---"

# --- Evaluate result ---
OUTPUT_CONTENT=$(cat "$OUTPUT_FILE" 2>/dev/null || true)

# Clean up
rm -f "$OUTPUT_FILE" "$SETTINGS_FILE"

# 1. Non-zero exit code is a clear failure (includes timeout exit 124)
if [ "$EXIT_CODE" -ne 0 ]; then
    echo "  FAILED (non-zero exit: $EXIT_CODE)"
    exit 1
fi

# 2. Empty response is a failure
if [ -z "$OUTPUT_CONTENT" ]; then
    echo "  FAILED (empty response)"
    exit 1
fi

# 3. OpenAI path: the body must carry assistant content
if [ "$PROTOCOL" = "openai" ]; then
    if [ -z "$(extract_chat_content "$OUTPUT_CONTENT")" ]; then
        RELAY_ERROR=$(extract_error_message "$OUTPUT_CONTENT")
        if [ -n "$RELAY_ERROR" ]; then
            echo "  FAILED (relay error: $RELAY_ERROR)"
        else
            echo "  FAILED (no assistant content in OpenAI response)"
        fi
        exit 1
    fi
fi

echo "  SUCCESS"
exit 0
