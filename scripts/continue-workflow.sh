#!/usr/bin/env bash
# continue-workflow.sh - Re-dispatch this workflow so a 6h-capped GitHub job does
# not end the keepalive loop: the script stops just before the cap, the workflow
# then calls this to queue the next run with the same inputs.
# Usage: continue-workflow.sh <workflow-file>         (e.g. keepalive.yml)
#
# Env: GH_TOKEN or GITHUB_TOKEN  - needs actions:write (workflows set
#                                  "permissions: actions: write")
#      GITHUB_REPOSITORY         - owner/repo (set by Actions)
#      GITHUB_REF_NAME           - branch to run on (default main)
#      WORKFLOW_INPUTS_JSON      - inputs to replay, e.g.
#                                  ${{ toJSON(github.event.inputs) }}
#
# Prints why and exits 0 when it cannot dispatch (e.g. running locally).
set -euo pipefail

WORKFLOW="${1:?用法: $0 <workflow-file>}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
REPO="${GITHUB_REPOSITORY:-}"
REF="${GITHUB_REF_NAME:-main}"
INPUTS="${WORKFLOW_INPUTS_JSON:-}"

if [ -z "$TOKEN" ] || [ -z "$REPO" ]; then
    echo "跳过续跑：不在 GitHub Actions 里（缺少 GH_TOKEN / GITHUB_REPOSITORY）"
    exit 0
fi

case "$INPUTS" in
    ""|"null"|"{}") INPUTS="{}" ;;
esac

echo "续跑：重新触发 ${WORKFLOW}（ref=${REF}）..."
if curl -sS --fail-with-body -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW}/dispatches" \
    -d "{\"ref\":\"${REF}\",\"inputs\":${INPUTS}}"; then
    echo "已触发下一段运行。"
else
    echo "续跑失败：无法 dispatch ${WORKFLOW}（检查 GH_TOKEN 是否有 actions: write 权限）" >&2
    exit 1
fi
