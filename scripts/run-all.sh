#!/usr/bin/env bash
# run-all.sh - Batch health-check runner with internal 50-minute loop
# Designed for a single GitHub Actions container: runs rounds until ~5h58m time limit.
# Supports local usage via .env file or ANYROUTER_TOKENS env var.
# Usage: run-all.sh [--once]
#
# Pacing env vars:
#   REQUEST_INTERVAL_SEC - seconds between two consecutive requests; when set it
#                          wins over the defaults below and is used both between
#                          tokens and between rounds (blank = legacy pacing)
#   SLOW_INTERVAL_MIN    - once one request comes back healthy, slow down to this
#                          keepalive pace in minutes (default 30, 0 = stay fast)
#   SLEEP_BETWEEN_TOKENS - default 30s (+/- 10s jitter) between tokens
#   SLEEP_BETWEEN_ROUNDS - default 3000s between rounds
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Parse args ---
ONCE=false
if [ "${1:-}" = "--once" ]; then
    ONCE=true
fi

# --- Configuration ---
BASE_URL="${BASE_URL:-https://anyrouter.top}"
MODEL="${MODEL:-gpt-6-astra}"
SLEEP_BETWEEN_TOKENS="${SLEEP_BETWEEN_TOKENS:-30}"         # seconds between tokens
SLEEP_BETWEEN_ROUNDS="${SLEEP_BETWEEN_ROUNDS:-3000}"       # ~50 minutes between rounds
# Fixed seconds between two consecutive requests. When set it wins over both
# defaults above, so "one request every N seconds" also holds between rounds.
REQUEST_INTERVAL_SEC="${REQUEST_INTERVAL_SEC:-}"
# Blank or whitespace-only (e.g. someone typed a space in the Actions box) means
# "not set": fall back to the built-in pacing below.
REQUEST_INTERVAL_SEC="$(printf '%s' "$REQUEST_INTERVAL_SEC" | tr -d '[:space:]')"
if [ -n "$REQUEST_INTERVAL_SEC" ]; then
    case "$REQUEST_INTERVAL_SEC" in
        *[!0-9]*)
            echo "ERROR: REQUEST_INTERVAL_SEC must be a whole number of seconds (got '$REQUEST_INTERVAL_SEC')" >&2
            exit 1
            ;;
    esac
    SLEEP_BETWEEN_TOKENS="$REQUEST_INTERVAL_SEC"
    SLEEP_BETWEEN_ROUNDS="$REQUEST_INTERVAL_SEC"
fi
# Slow keepalive pace to fall back to after the first healthy answer (minutes).
# 0 disables the slow-down, and it only kicks in when a fast interval is set.
SLOW_INTERVAL_MIN="${SLOW_INTERVAL_MIN:-30}"
case "$SLOW_INTERVAL_MIN" in
    *[!0-9]*)
        echo "ERROR: SLOW_INTERVAL_MIN must be a whole number of minutes (got '$SLOW_INTERVAL_MIN')" >&2
        exit 1
        ;;
esac
SLOW_INTERVAL_SEC=$(( SLOW_INTERVAL_MIN * 60 ))
if [ -z "$REQUEST_INTERVAL_SEC" ]; then
    SLOW_INTERVAL_SEC=0
fi
SLOWDOWN_ACTIVE=false
MAX_DURATION_SEC="${MAX_DURATION_SEC:-21500}"               # ~5h58m (just under 6h limit)
QQ_EMAIL="${QQ_EMAIL:-}"
QQ_SMTP_AUTH_CODE="${QQ_SMTP_AUTH_CODE:-}"

# --- Load tokens ---
load_tokens() {
    # 1) Try env var
    if [ -n "${ANYROUTER_TOKENS:-}" ]; then
        echo "$ANYROUTER_TOKENS"
        return
    fi
    # 2) Try .env file
    if [ -f "$SCRIPT_DIR/../.env" ]; then
        local val
        val=$(grep -E '^ANYROUTER_TOKENS=' "$SCRIPT_DIR/../.env" 2>/dev/null | sed 's/^ANYROUTER_TOKENS=//' | sed 's/^"//;s/"$//' || true)
        if [ -n "$val" ]; then
            echo "$val" | tr ',' '\n'
            return
        fi
    fi
    echo "ERROR: No tokens found. Set ANYROUTER_TOKENS env var or create .env file." >&2
    exit 1
}

# --- Email report ---
send_email() {
    local subject="$1" body="$2"
    if [ -z "$QQ_EMAIL" ] || [ -z "$QQ_SMTP_AUTH_CODE" ]; then
        echo "  (Skipping email: QQ_EMAIL or QQ_SMTP_AUTH_CODE not configured)"
        return 0
    fi

    # Verify curl supports SMTP (GitHub Actions curl usually does)
    if ! curl --version 2>/dev/null | grep -qi "smtp"; then
        echo "  Email failed: curl was not compiled with SMTP support"
        return 1
    fi

    # Write email to temp file (more reliable than here-string + stdin)
    local mail_file
    mail_file=$(mktemp)
    cat > "$mail_file" <<EOF
From: $QQ_EMAIL
To: $QQ_EMAIL
Subject: $subject
Content-Type: text/plain; charset=utf-8

$body
EOF

    echo "  Sending email via QQ SMTP to $QQ_EMAIL ..."

    # SMTP_DEBUG=true (Actions: smtp_debug) prints the raw SMTP conversation,
    # which is the fastest way to see why QQ rejects a message.
    local curl_opts=()
    if [ "${SMTP_DEBUG:-}" = "true" ]; then
        curl_opts+=(-v)
        echo "  (SMTP_DEBUG: printing the raw SMTP conversation)"
    fi

    local curl_exit=0 url
    # QQ defaults: implicit TLS first, then the STARTTLS port. SMTP_URL replaces
    # them entirely (QQ Mail refuses to send from cloud/datacenter IPs such as
    # GitHub runners, so another provider is often the only way out).
    local smtp_urls=("smtps://smtp.qq.com:465" "smtp://smtp.qq.com:587")
    if [ -n "${SMTP_URL:-}" ]; then
        smtp_urls=("$SMTP_URL")
    fi
    for url in "${smtp_urls[@]}"; do
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
        echo "  Send via ${url} failed (curl exit: $curl_exit)"
    done

    rm -f "$mail_file"

    if [ "$curl_exit" -eq 0 ]; then
        echo "  Email sent to $QQ_EMAIL"
        return 0
    else
        echo "  Email FAILED (curl exit: $curl_exit)"
        echo "  Common causes:"
        echo "    - QQ_SMTP_AUTH_CODE is wrong (it is NOT your QQ password)"
        echo "    - Generate it at: QQ Mail -> Settings -> Account -> POP3/IMAP/SMTP"
        echo "    - Network/firewall blocking smtps://smtp.qq.com:465"
        echo "    - QQ refuses to send from cloud IPs (GitHub runners): set SMTP_URL to another provider"
        echo "    - Run again with SMTP_DEBUG=true (Actions input: smtp_debug) to see QQ's raw reply"
        return 1
    fi
}

# --- Load tokens ---
TOKENS_DATA=$(load_tokens)
mapfile -t TOKENS <<< "$TOKENS_DATA"
if [ ${#TOKENS[@]} -eq 0 ]; then
    echo "ERROR: No tokens loaded. Exiting." >&2
    exit 1
fi
echo "Loaded ${#TOKENS[@]} token(s)"
echo "Base URL: $BASE_URL"
echo "Model: $MODEL"
if [ -n "$REQUEST_INTERVAL_SEC" ]; then
    echo "Request interval: ${REQUEST_INTERVAL_SEC}s (fixed, no jitter)"
    if [ "$SLOW_INTERVAL_SEC" -gt 0 ]; then
        echo "Slow-down after first success: ${SLOW_INTERVAL_MIN}min keepalive pace"
    else
        echo "Slow-down after first success: disabled"
    fi
fi
echo ""

START_TIME=$(date +%s)
ROUND=1
ALL_RESULTS=""
HAS_SENT_REPORT=false

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    REMAINING=$((MAX_DURATION_SEC - ELAPSED))

    if [ "$REMAINING" -le 0 ]; then
        echo "=== Time limit reached. Exiting. ==="
        break
    fi

    echo "========================================"
    echo " Round $ROUND  |  $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo " Elapsed: ${ELAPSED}s  |  Remaining: ~${REMAINING}s"
    echo "========================================"

    ROUND_RESULTS=""
    ROUND_SUCCESS=0
    ROUND_FAIL=0

    for i in "${!TOKENS[@]}"; do
        token="${TOKENS[$i]}"
        token_preview="${token:0:5}..."

        # Check remaining time before each token
        NOW=$(date +%s)
        if [ $((NOW - START_TIME)) -ge "$MAX_DURATION_SEC" ]; then
            echo "Time limit reached mid-round. Breaking."
            break
        fi

        echo "[$((i+1))/${#TOKENS[@]}] Testing $token_preview ..."

        if result=$(bash "$SCRIPT_DIR/keepalive.sh" "$token" "$BASE_URL" "$MODEL" 2>&1); then
            echo "$result"
            echo "  ✓ $token_preview is active"
            ROUND_RESULTS+="  ✓ $token_preview is active"$'\n'
            ROUND_SUCCESS=$((ROUND_SUCCESS + 1))

            # First healthy answer: stop hammering and keep the account warm at
            # the slow pace instead (rounds become SLOW_INTERVAL_SEC apart, so
            # every token is exercised once per SLOW_INTERVAL_MIN minutes).
            if [ "$SLOWDOWN_ACTIVE" = false ] && [ "$SLOW_INTERVAL_SEC" -gt 0 ]; then
                SLOWDOWN_ACTIVE=true
                SLEEP_BETWEEN_ROUNDS="$SLOW_INTERVAL_SEC"
                echo "  >>> First healthy answer - slowing down to a ${SLOW_INTERVAL_MIN}min keepalive pace"
                ROUND_RESULTS+="  >>> First healthy answer: switched to the ${SLOW_INTERVAL_MIN}min keepalive pace"$'\n'
            fi
        else
            echo "$result"
            echo "  ✗ $token_preview failed"
            ROUND_RESULTS+="  ✗ $token_preview failed"$'\n'
            ROUND_FAIL=$((ROUND_FAIL + 1))
        fi

        # Pace the requests: the fixed interval when the user set one, otherwise
        # the legacy 30s +/- 10s jitter that avoids looking like a burst.
        if [ "$i" -lt "$(( ${#TOKENS[@]} - 1 ))" ]; then
            if [ -n "$REQUEST_INTERVAL_SEC" ]; then
                WAIT_SEC="$REQUEST_INTERVAL_SEC"
            else
                WAIT_SEC=$(( SLEEP_BETWEEN_TOKENS + (RANDOM % 21) - 10 ))
                [ "$WAIT_SEC" -lt 10 ] && WAIT_SEC=10
            fi
            echo "  Waiting ${WAIT_SEC}s ..."
            sleep "$WAIT_SEC"
        fi
    done

    # Accumulate round results
    ALL_RESULTS+="--- Round $ROUND ($(date '+%Y-%m-%d %H:%M')) ---"$'\n'
    ALL_RESULTS+="$ROUND_RESULTS"$'\n'
    ALL_RESULTS+="Round $ROUND summary: $ROUND_SUCCESS success, $ROUND_FAIL failed"$'\n'$'\n'

    echo ""
    echo "--- Round $ROUND summary: $ROUND_SUCCESS success, $ROUND_FAIL failed ---"

    ROUND=$((ROUND + 1))

    # If --once mode, exit after the first round
    if [ "$ONCE" = true ]; then
        echo ""
        echo "=== --once mode: single round complete. Exiting. ==="
        break
    fi

    # Check if we should send final report (last round before time limit)
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    REMAINING=$((MAX_DURATION_SEC - ELAPSED))

    if [ "$REMAINING" -le "$((SLEEP_BETWEEN_ROUNDS + 120))" ] && [ "$HAS_SENT_REPORT" = false ]; then
        HAS_SENT_REPORT=true
        echo ""
        echo "=== Sending final report ==="
        send_email "Anyrouter Keepalive Report ($(date '+%Y-%m-%d'))" "$ALL_RESULTS" || true
        echo ""

        # Do one more round if time allows, but signal it's the last
        if [ "$REMAINING" -le 0 ]; then
            break
        fi
    fi

    # Sleep until next round (if we have time)
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    REMAINING=$((MAX_DURATION_SEC - ELAPSED))

    if [ "$REMAINING" -gt "$SLEEP_BETWEEN_ROUNDS" ]; then
        echo "Sleeping ${SLEEP_BETWEEN_ROUNDS}s until round $ROUND ..."
        sleep "$SLEEP_BETWEEN_ROUNDS"
    elif [ "$REMAINING" -gt 60 ]; then
        echo "Sleeping ${REMAINING}s (remaining time) ..."
        sleep "$REMAINING"
    else
        echo "Time limit reached."
    fi
done

# Final summary
echo ""
echo "========================================"
echo " All rounds complete."
echo "$ALL_RESULTS"
echo "========================================"

# Send one final report if we never sent one (e.g. very short run)
if [ "$HAS_SENT_REPORT" = false ]; then
    send_email "Anyrouter Keepalive Report ($(date '+%Y-%m-%d'))" "$ALL_RESULTS" || true
fi

echo "Done."
