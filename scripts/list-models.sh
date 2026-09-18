#!/usr/bin/env bash
# list-models.sh - List the model ids an OpenAI-compatible relay accepts
# Usage: list-models.sh <token> [base_url]
#
# Useful before setting MODEL: relays reject model ids they do not serve,
# e.g. {"error":"当前 API 不支持所选模型 gpt-6-astra","type":"error"}
set -euo pipefail

TOKEN="${1:?用法: $0 <token> [base_url]}"
BASE_URL="${2:-https://anyrouter.top}"

BASE="${BASE_URL%/}"
case "$BASE" in
    */models)              URL="$BASE" ;;
    */chat/completions)    URL="${BASE%/chat/completions}/models" ;;
    */v1)                  URL="$BASE/models" ;;
    *)                     URL="$BASE/v1/models" ;;
esac

echo "GET $URL"
BODY=$(curl -sS --max-time 30 -H "Authorization: Bearer $TOKEN" "$URL" || true)

if [ -z "$BODY" ]; then
    echo "FAILED (响应为空 - 网络不通或主机地址不对？)" >&2
    exit 1
fi

if command -v jq >/dev/null 2>&1; then
    IDS=$(printf '%s' "$BODY" | jq -r '(.data // .models // [])[]? | (.id // .name // empty)' 2>/dev/null || true)
    if [ -n "$IDS" ]; then
        printf '%s\n' "$IDS"
        exit 0
    fi
fi

# Fallback without jq: pull every "id":"..." pair out of the payload
IDS=$(printf '%s' "$BODY" | tr ',' '\n' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | sort -u)
if [ -n "$IDS" ]; then
    printf '%s\n' "$IDS"
    exit 0
fi

echo "FAILED (响应里没有模型列表)。原始响应如下:" >&2
printf '%s\n' "$BODY" >&2
exit 1
