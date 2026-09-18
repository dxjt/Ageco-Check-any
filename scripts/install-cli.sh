#!/usr/bin/env bash
# install-cli.sh - Install the CLI that a health check can drive
# Usage: install-cli.sh claude|codex
#
#   claude - Claude Code CLI (Anthropic Messages API), installed from claude.ai
#   codex  - OpenAI Codex CLI, installed from npm (@openai/codex)
#
# Both installers are skipped when the CLI is already on PATH, so it is safe to
# call this from a workflow step or locally before a run.
set -euo pipefail

TARGET="${1:?用法: $0 claude|codex}"

# GitHub Actions picks up PATH additions from later steps via $GITHUB_PATH
add_to_path() {
    if [ -n "${GITHUB_PATH:-}" ]; then
        echo "$1" >> "$GITHUB_PATH"
    fi
}

case "$TARGET" in
    claude)
        if command -v claude >/dev/null 2>&1; then
            echo "claude CLI 已安装: $(claude --version 2>/dev/null || echo '版本未知')"
            exit 0
        fi
        echo "正在安装 Claude Code CLI ..."
        curl -fsSL https://claude.ai/install.sh | bash
        add_to_path "$HOME/.local/bin"
        export PATH="$HOME/.local/bin:$PATH"
        ;;
    codex)
        if command -v codex >/dev/null 2>&1; then
            echo "codex CLI 已安装: $(codex --version 2>/dev/null || echo '版本未知')"
            exit 0
        fi
        if ! command -v npm >/dev/null 2>&1; then
            echo "ERROR: 安装 Codex CLI 需要 npm" >&2
            exit 1
        fi
        echo "正在安装 Codex CLI ..."
        if ! npm install -g @openai/codex; then
            echo "npm install 失败，改用 sudo 重试 ..." >&2
            sudo npm install -g @openai/codex
        fi
        ;;
    *)
        echo "用法: $0 claude|codex" >&2
        exit 1
        ;;
esac

case "$TARGET" in
    claude)
        if command -v claude >/dev/null 2>&1; then
            echo "claude: $(claude --version 2>/dev/null || echo '已安装')"
        else
            echo "claude 已安装，但还不在 PATH 中 - 请把 \$HOME/.local/bin 加入 PATH"
        fi
        ;;
    codex)
        if command -v codex >/dev/null 2>&1; then
            echo "codex: $(codex --version 2>/dev/null || echo '已安装')"
        else
            echo "codex 已安装，但还不在 PATH 中"
        fi
        ;;
esac
