#!/usr/bin/env bash
# monitor-recovery.sh - Poll all tokens every 30min, send round summary, early-exit when fast
# Designed for manual-trigger GitHub Actions workflow (6h container).
# Reuses keepalive.sh for health checks.
# Usage: monitor-recovery.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Configuration ---
BASE_URL="${BASE_URL:-https://anyrouter.top}"
MODEL="${MODEL:-gpt-6-astra}"
POLL_INTERVAL="${POLL_INTERVAL:-1800}"          # 30 minutes between rounds
# Fixed seconds between two consecutive requests. When set it also replaces the
# poll interval, so a single token is exercised once every N seconds.
REQUEST_INTERVAL_SEC="${REQUEST_INTERVAL_SEC:-}"
# Blank or whitespace-only (e.g. someone typed a space in the Actions box) means
# "not set": fall back to the built-in pacing below.
REQUEST_INTERVAL_SEC="$(printf '%s' "$REQUEST_INTERVAL_SEC" | tr -d '[:space:]')"
if [ -n "$REQUEST_INTERVAL_SEC" ]; then
    case "$REQUEST_INTERVAL_SEC" in
        *[!0-9]*)
            echo "ERROR: REQUEST_INTERVAL_SEC 必须是整数秒（当前值 '$REQUEST_INTERVAL_SEC'）" >&2
            exit 1
            ;;
    esac
    POLL_INTERVAL="$REQUEST_INTERVAL_SEC"
fi
MAX_DURATION_SEC="${MAX_DURATION_SEC:-21500}"   # ~5h58m (just under 6h)
QQ_EMAIL="${QQ_EMAIL:-}"
QQ_SMTP_AUTH_CODE="${QQ_SMTP_AUTH_CODE:-}"

# Beijing time helper
beijing_ts() {
    TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S CST'
}

# --- Load tokens (reused from run-all.sh) ---
load_tokens() {
    if [ -n "${ANYROUTER_TOKENS:-}" ]; then
        echo "$ANYROUTER_TOKENS"
        return
    fi
    if [ -f "$SCRIPT_DIR/../.env" ]; then
        local val
        val=$(grep -E '^ANYROUTER_TOKENS=' "$SCRIPT_DIR/../.env" 2>/dev/null | sed 's/^ANYROUTER_TOKENS=//' | sed 's/^"//;s/"$//' || true)
        if [ -n "$val" ]; then
            echo "$val" | tr ',' '\n'
            return
        fi
    fi
    echo "ERROR: 没有找到 token。请设置 ANYROUTER_TOKENS 环境变量，或创建 .env 文件。" >&2
    exit 1
}

# --- Send email alert (reused from run-all.sh) ---
send_email() {
    local subject="$1" body="$2"
    if [ -z "$QQ_EMAIL" ] || [ -z "$QQ_SMTP_AUTH_CODE" ]; then
        echo "  (跳过邮件: 未配置 QQ_EMAIL 或 QQ_SMTP_AUTH_CODE)"
        return 0
    fi
    if ! curl --version 2>/dev/null | grep -qi "smtp"; then
        echo "  邮件发送失败: 当前 curl 未编译 SMTP 支持"
        return 1
    fi
    local mail_file
    mail_file=$(mktemp)
    cat > "$mail_file" <<EOF
From: $QQ_EMAIL
To: $QQ_EMAIL
Subject: $subject
Content-Type: text/plain; charset=utf-8

$body
EOF
    echo "  正在通过 QQ SMTP 发邮件到 $QQ_EMAIL ..."

    # SMTP_DEBUG=true (Actions: smtp_debug) prints the raw SMTP conversation,
    # which is the fastest way to see why QQ rejects a message.
    local curl_opts=()
    if [ "${SMTP_DEBUG:-}" = "true" ]; then
        curl_opts+=(-v)
        echo "  (SMTP_DEBUG: 打印原始 SMTP 会话)"
    fi

    local curl_exit=0 url
    # Try the implicit-TLS port first, then the STARTTLS port: some networks (and
    # some QQ front-ends) reject one but accept the other.
    for url in "smtps://smtp.qq.com:465" "smtp://smtp.qq.com:587"; do
        curl_exit=0
        curl -sS --ssl-reqd --fail-with-body ${curl_opts[@]+"${curl_opts[@]}"} \
            --url "$url" \
            --user "$QQ_EMAIL:$QQ_SMTP_AUTH_CODE" \
            --login-options "AUTH=LOGIN" \
            --mail-from "$QQ_EMAIL" \
            --mail-rcpt "$QQ_EMAIL" \
            --upload-file - < "$mail_file" \
            || curl_exit=$?
        if [ "$curl_exit" -eq 0 ]; then
            break
        fi
        echo "  通过 ${url} 发送失败 (curl 退出码: $curl_exit)"
    done

    rm -f "$mail_file"
    if [ "$curl_exit" -eq 0 ]; then
        echo "  邮件已发送到 $QQ_EMAIL"
        return 0
    else
        echo "  邮件发送 FAILED (curl 退出码: $curl_exit)"
        echo "  常见原因:"
        echo "    - QQ_SMTP_AUTH_CODE 不对（它不是 QQ 密码，而是授权码）"
        echo "    - 生成位置: QQ 邮箱 -> 设置 -> 账号 -> POP3/IMAP/SMTP 服务"
        echo "    - 网络/防火墙拦住了 smtps://smtp.qq.com:465"
        echo "    - QQ 拒绝从机房 IP（GitHub runner）发信: 请把 SMTP_URL 换成别的邮箱服务"
        echo "    - 用 SMTP_DEBUG=true（Actions 输入 smtp_debug）重跑，可看到 QQ 的原始回复"
        return 1
    fi
}

# --- Main ---
TOKENS_DATA=$(load_tokens)
mapfile -t TOKENS <<< "$TOKENS_DATA"
if [ ${#TOKENS[@]} -eq 0 ]; then
    echo "ERROR: 没有加载到 token，退出。" >&2
    exit 1
fi
echo "已加载 ${#TOKENS[@]} 个 token"
echo "接口地址: $BASE_URL"
echo "模型: $MODEL"
if [ -n "$REQUEST_INTERVAL_SEC" ]; then
    echo "请求间隔: ${REQUEST_INTERVAL_SEC}s（固定，无抖动）"
else
    echo "轮询间隔: ${POLL_INTERVAL}s"
fi
echo ""

declare -A PREV_STATES   # "success" or "failed"

START_TIME=$(date +%s)
ROUND=1

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    REMAINING=$((MAX_DURATION_SEC - ELAPSED))

    if [ "$REMAINING" -le 0 ]; then
        echo "=== 达到时间上限，退出 ==="
        break
    fi

    echo "============================================="
    echo " 第 $ROUND 轮  |  $(beijing_ts)"
    echo " 已用: ${ELAPSED}s  |  剩余: ~${REMAINING}s"
    echo "============================================="

    # Per-round tracking
    TOKEN_RESULTS=()
    TOKEN_TIMES=()       # response time (seconds), 0 for failed
    ALL_SUCCESS=true
    MAX_TIME=0

    for i in "${!TOKENS[@]}"; do
        token="${TOKENS[$i]}"
        token_preview="${token:0:5}..."

        # Check remaining time before each token
        NOW=$(date +%s)
        if [ $((NOW - START_TIME)) -ge "$MAX_DURATION_SEC" ]; then
            echo "已达时间上限，中途结束本轮。"
            break
        fi

        echo "[$((i+1))/${#TOKENS[@]}] 正在测试 $token_preview ..."

        CHECK_START=$(date +%s)
        if result=$(bash "$SCRIPT_DIR/keepalive.sh" "$token" "$BASE_URL" "$MODEL" 2>&1); then
            CHECK_END=$(date +%s)
            response_time=$((CHECK_END - CHECK_START))
            echo "$result"
            echo "  ✓ $token_preview 正常（${response_time}s）"

            TOKEN_RESULTS+=("✓ $token_preview 正常（${response_time}s）")
            TOKEN_TIMES+=("$response_time")
            PREV_STATES[$token]="success"
            [ "$response_time" -gt "$MAX_TIME" ] && MAX_TIME=$response_time
        else
            echo "$result"
            echo "  ✗ $token_preview 失败"
            TOKEN_RESULTS+=("✗ $token_preview 失败")
            TOKEN_TIMES+=("0")
            PREV_STATES[$token]="failed"
            ALL_SUCCESS=false
        fi

        # Pace the requests: fixed interval when set, legacy jitter otherwise
        if [ "$i" -lt "$(( ${#TOKENS[@]} - 1 ))" ]; then
            if [ -n "$REQUEST_INTERVAL_SEC" ]; then
                WAIT_SEC="$REQUEST_INTERVAL_SEC"
            else
                WAIT_SEC=$(( 30 + (RANDOM % 21) - 10 ))
                [ "$WAIT_SEC" -lt 10 ] && WAIT_SEC=10
            fi
            echo "  等待 ${WAIT_SEC}s ..."
            sleep "$WAIT_SEC"
        fi
    done

    # --- End of round: build summary ---
    ROUND_SUMMARY=""
    SUCCESS_COUNT=0
    FAIL_COUNT=0

    for i in "${!TOKENS[@]}"; do
        ROUND_SUMMARY+="  ${TOKEN_RESULTS[$i]}"$'\n'
        if [ "${PREV_STATES[${TOKENS[$i]}]}" = "success" ]; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    done

    ROUND_SUMMARY+=$'\n'"汇总: 成功 $SUCCESS_COUNT，失败 $FAIL_COUNT"

    echo ""
    echo "--- 第 $ROUND 轮汇总: 成功 $SUCCESS_COUNT，失败 $FAIL_COUNT ---"
    echo ""

    # --- Decide action ---
    if [ "$ALL_SUCCESS" = true ] && [ "$MAX_TIME" -lt 30 ]; then
        # All healthy and fast — early exit
        echo ">>> 所有 token 正常（最大响应 ${MAX_TIME}s < 30s）。发送“快用”邮件并退出。"
        send_email \
            "快用！现在状态超好，不接着测了" \
            "Anyrouter 已全面恢复，响应极快，建议立即使用！

$(beijing_ts)

各 token 状态：
$ROUND_SUMMARY

最大响应时间: ${MAX_TIME}s
所有 token 均正常工作且响应时间 < 30 秒，状态超好！检测到此结束。"
        echo ""
        echo "=== 提前退出: 全部正常且响应很快 ==="
        break
    fi

    # Send normal round summary
    if [ "$ALL_SUCCESS" = true ]; then
        send_email \
            "Anyrouter 监控报告 - 第${ROUND}轮（全部可用）" \
            "轮次: 第 ${ROUND} 轮
检测时间: $(beijing_ts)

各 token 状态：
$ROUND_SUMMARY

最大响应时间: ${MAX_TIME}s
全部可用，但响应时间未达到 30 秒以内的超优标准，继续监控。"
    else
        send_email \
            "Anyrouter 监控报告 - 第${ROUND}轮（${FAIL_COUNT}个不可用）" \
            "轮次: 第 ${ROUND} 轮
检测时间: $(beijing_ts)

各 token 状态：
$ROUND_SUMMARY

仍有 ${FAIL_COUNT} 个 token 不可用，继续监控。"
    fi

    ROUND=$((ROUND + 1))

    # --- Sleep until next poll ---
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    REMAINING=$((MAX_DURATION_SEC - ELAPSED))

    if [ "$REMAINING" -gt "$POLL_INTERVAL" ]; then
        echo ""
        echo "--- 下一轮在 ${POLL_INTERVAL}s 后（$((POLL_INTERVAL / 60)) 分钟）---"
        sleep "$POLL_INTERVAL"
    elif [ "$REMAINING" -gt 60 ]; then
        echo ""
        echo "--- 时间快到了，最后休眠 ${REMAINING}s ---"
        sleep "$REMAINING"
    else
        echo "已达到时间上限。"
    fi
done

echo ""
echo "========================================"
echo " 监控结束。"
echo " 总轮数: $ROUND"
echo "========================================"
