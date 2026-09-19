# Anyrouter Keepalive

对 Anyrouter Claude API 中转站的多账号执行健康检查（保活）与恢复监控，通过 GitHub Actions 运行，让账号在调度队列中保持活跃状态，在使用时获得更高优先级。除 Claude 以外，也支持任意 OpenAI 格式的模型 id（例如 `gpt-6-astra`），详见「模型与协议」。

## 工作流一览

| 工作流 | 触发方式 | 用途 |
|---|---|---|
| **Keepalive** (`keepalive.yml`) | 定时 + 手动 | 自动保活，**默认不停止**（每段 ~5h50m 自动续跑下一段），每 50 分钟轮询一轮 |
| **Keepalive Once** (`keepalive-once.yml`) | 手动 | 单次快速测活（只跑一轮） |
| **Recovery Monitor** (`monitor-recovery.yml`) | 手动 | 每 30 分钟轮询，发现恢复立刻通知，全通且响应 <30s 自动退出 |

## 工作原理

Anyrouter 的调度策略疑似为**账号级先来先用**。如果账号长时间没有请求，可能在队列中失去优先级。本项目通过定时发起轻量 API 调用让账号保持活跃（默认模型 `gpt-6-astra`，走 OpenAI Responses 协议；换成 `claude-*` 模型则走 Anthropic 协议）。

### Keepalive（保活）

- 每天 **UTC 18:00（北京时间 02:00）** 启动一个 GitHub Actions 容器
- 容器内部每 **50 分钟** 轮询一遍所有 token（避免 6 小时限制）
- 每个 token 发送一条随机轻量探针（默认 20 条，见 `scripts/prompts.txt`）：默认用 `curl` 直连 `/v1/responses`，Claude 模型则用 `claude -p` 模式
- 请求间隔可自定义（Actions 的 `interval` 输入 / `REQUEST_INTERVAL_SEC`），见「Prompt 池与请求间隔」
- 每段跑到 ~5 小时 50 分自动发送汇总报告邮件，然后**自动续跑下一段**（GitHub 单个 job 硬上限 6 小时，见「不会停止（自动续跑）」）
- 可选通过 QQ 邮箱接收最终报告

### Recovery Monitor（恢复监控）

- **手动触发**，启动一个 6 小时容器，每 **30 分钟** 轮询所有 token
- 每轮结束后发送**汇总邮件**（北京时间），列出每个 token 的状态和响应时间
- **早期退出**：当全部 token 正常且最大响应时间 < 30 秒时，发「快用！状态超好」邮件并自动终止
- 适合等待 Anyrouter 从不可用状态恢复的场景

## 快速开始

### 1. Fork 仓库

Fork 本仓库到你的 GitHub 账号下。

### 2. 配置 Secrets

在仓库的 **Settings → Secrets and variables → Actions** 中添加：

| Secret 名称 | 说明 | 是否必需 |
|---|---|---|
| `ANYROUTER_TOKENS` | 你的 Anyrouter token，每行一个 | ✅ 必需 |
| `QQ_EMAIL` | QQ 邮箱地址，用于接收报告 | ❌ 可选 |
| `QQ_SMTP_AUTH_CODE` | QQ 邮箱 SMTP 授权码 | ❌ 可选 |

**ANYROUTER_TOKENS 格式：**（每行一个 token；Anyrouter 用 `sk-ant-...`，换用其他中转站时填该站的 key）
```
sk-ant-xxx111
sk-ant-xxx222
sk-ant-xxx333
```

### 3. 启用 Actions

进入 **Actions** 页面，点击 **"I understand my workflows, go ahead and enable them"**。

| 工作流 | 手动触发路径 |
|---|---|
| 保活（定时） | Actions → Anyrouter Keepalive → Run workflow |
| 保活（单次） | Actions → Anyrouter Keepalive (Once) → Run workflow |
| 恢复监控 | Actions → Anyrouter Recovery Monitor → Run workflow |

三个工作流在手动触发时都可自定义 `base_url`、`model`、`protocol`、`interval`（请求间隔秒数）、`install_cli`（跑之前装不装 CLI）和 `auto_continue`（是否自动续跑），默认使用 `gpt-6-astra`（Responses 协议）。Keepalive 默认不停止：`auto_continue=true`，每段长度由 `max_duration_sec` 决定（默认 21000 ≈ 5h50m）。

## 模型与协议

测活请求支持两种协议，由 `PROTOCOL` 环境变量控制，默认 `auto`（按模型 id 自动判断）：

| PROTOCOL | 什么时候用 | 实际走的通道 |
|---|---|---|
| `auto`（默认） | 不用管，按模型 id 自动判断 | 以 `claude` 开头 → Anthropic Messages API；其他 id（如 `gpt-6-astra`）→ Responses |
| `anthropic` | 想强制走 Claude Code CLI | Anthropic Messages API（`claude -p` + `~/.claude/settings.json`） |
| `responses` | 想强制走 `/v1/responses`：id 是 `claude*` 但中转站只认 OpenAI 接口，或不想装 Claude CLI | `POST {BASE_URL}/v1/responses`（curl 直连） |
| `openai` | 中转站只认老的 chat-completions 接口 | `POST {BASE_URL}/v1/chat/completions`（curl 直连） |
| `codex` | 想用 Codex CLI 发请求（不走 curl） | `codex exec` 发出的 `POST {BASE_URL}/v1/responses` |

> `auto` 只负责「猜」，后三个是「强制覆盖」。所以 `auto` 和 `responses` 不是重复：一个是按 id 自动选，一个是不管 id 都走 Responses 接口——用来对付「模型 id 和可用接口对不上」的中转站。

### 通过 CLI 调用（Claude Code CLI / Codex CLI）

`anthropic` 协议用 Claude Code CLI，`codex` 协议用 Codex CLI，两者都要先装 CLI：

```bash
# 装 CLI（已经装过会自动跳过，不会重复安装）
bash scripts/install-cli.sh claude
bash scripts/install-cli.sh codex

# 用 Codex CLI 发请求：脚本会临时生成一个 CODEX_HOME，不会动你自己的 ~/.codex/config.toml
PROTOCOL=codex MODEL="gpt-6-astra" bash scripts/keepalive.sh "$TOKEN"

# 用 Claude Code CLI 发请求
PROTOCOL=anthropic MODEL='claude-opus-4-8[1m]' bash scripts/keepalive.sh "$TOKEN"
```

Actions 里用 `install_cli` 输入决定跑之前装不装：

| install_cli | 行为 |
|---|---|
| `auto`（默认） | 只装这次协议需要的：`anthropic` / `claude*` 装 Claude CLI，`codex` 装 Codex CLI；`responses` / `openai` 什么都不装（最快，约 2 秒跑完） |
| `yes` | Claude CLI 和 Codex CLI 都装（两个都能用，切换协议不用重跑） |
| `no` | 都不装：依赖 runner 上已存在；缺 CLI 时脚本会直接报 `未找到 claude CLI` / `未找到 codex CLI` |

- Codex CLI 走的是流式请求（`stream: true`），中转站必须支持 SSE 流式返回；只支持整包返回的站点会报 `stream disconnected before completion`，那种情况用 `PROTOCOL=responses` 的 curl 直连即可。
- Codex CLI 会把请求发到 `{BASE_URL}/v1/responses`（`wire_api = "responses"`），并带上一堆工具定义，报文比 curl 探针大得多；只想测「账号是否活着」建议还是用默认的 `responses`。
- **重试即中止**：CLI 输出里一旦出现重试行（codex 会打印 `ERROR: Reconnecting... 1/5` 然后退避重试），脚本在**第一次重试就掐掉这次请求**并判定该 token 失败——不再等 5 次重试跑完，本轮只花几秒就进入下一次对话。判定条件用 `CLI_RETRY_ABORT_PATTERN`（`grep -E` 模式，默认 `Reconnecting`；设为空字符串则恢复成「等 CLI 自己结束」），日志会打印 `FAILED (Codex CLI 检测到重试，已提前中止本次请求: ERROR: Reconnecting... 1/5)`

> Codex CLI 从 npm 安装（`npm install -g @openai/codex`），Claude Code CLI 从 `https://claude.ai/install.sh` 安装。GitHub 的 runner 是一次性的，所以 `auto`/`yes` 每次运行都会装一遍；这也是为什么默认走 curl 的 `responses` 最省时间。

- 默认模型是 `gpt-6-astra`，走 Responses 协议；`claude-opus-4-8[1m]`、`claude-fable-5-1[1m]` 这类 id 走 Anthropic 协议。
- Responses 协议：`Authorization: Bearer <token>`，请求体为 `{"model", "input", "max_output_tokens", "stream": false}`，回复从 `output_text` 或 `output[].content[].text` 中取。
- Chat Completions 协议：请求体为 `{"model", "messages", "max_tokens", "stream": false}`，回复从 `choices[0].message.content` 中取。
- OpenAI 系通道用 `curl` 直连，不需要安装 Claude Code CLI；`MAX_TOKENS` 覆盖默认的 128，设为 `none` 则不发送 token 上限字段。
- `BASE_URL` 可写成 `https://relay.example.com`、`https://relay.example.com/v1` 或完整端点，脚本都会补全成 `/v1/responses`（或 `/v1/chat/completions`），不会重复拼接。
- 只要响应里没有 assistant 内容（例如返回 `{"error": ...}`），该 token 即判定为不可用；失败行的 `中转站报错:` 会带上中转站返回的原始错误。
- 中转站返回 `{"error":"当前 API 不支持所选模型 xxx"}` 说明该站点没有这个模型：先用 `bash scripts/list-models.sh <token> [base_url]` 查出它实际接受的 id，或把 `BASE_URL` 换成真正提供该模型的站点。

## Prompt 池与请求间隔

### Prompt 池

每次请求都会从池子里随机挑一条发送，池子由 `PROMPTS_FILE` 决定：

| 文件 | 内容 |
|---|---|
| `scripts/prompts.txt`（默认） | 20 条轻量探针，回复只要 1 个字符到一行，token 消耗最低、返回最快 |
| `scripts/prompts-engineering.txt` | 原来的 65 条工程提问池，想换回工程问题就用 `PROMPTS_FILE` 指定 |

池子文件每行一条 prompt，空行和以 `#` 开头的行会被忽略。相对路径先按仓库根目录解析，再按当前目录解析。

```bash
# 换回工程提问池
PROMPTS_FILE=scripts/prompts-engineering.txt bash scripts/keepalive.sh "$TOKEN"

# 用自己写的池子（绝对路径或相对路径都行）
PROMPTS_FILE=/path/to/my-prompts.txt bash scripts/keepalive.sh "$TOKEN"

# 批量 / 恢复监控同样生效（脚本会透传给 keepalive.sh）
PROMPTS_FILE=scripts/prompts-engineering.txt bash scripts/run-all.sh --once
```

### 请求间隔

`REQUEST_INTERVAL_SEC`（Actions 里叫 `interval`）控制两次请求之间隔多少秒：

- **留空（默认，只输入空格也算留空）**：token 之间 30 秒 ± 10 秒随机抖动，轮与轮之间 50 分钟（Keepalive）/ 30 分钟（Recovery Monitor），与旧版本一致
- **设为 N**：两次请求严格间隔 N 秒、不加抖动；同一轮内 token 之间如此，轮与轮之间也如此。所以只有一个 token 时，就是「每 N 秒发一次请求」
- **第一次成功就自动降速**：间隔模式下，一旦**第一次拿到正常回答**（响应里有内容、不是 error），立刻切到保活节奏——之后每轮（每个 token 一次）间隔 `slow_interval_min` 分钟（Actions 输入，默认 **30**）；填 `0` 表示成功后也保持快跑。日志会打印 `>>> 首次收到正常回复 - 降速到 30 分钟保活节奏`，邮件正文里也会带上这行
  - 这样就能「先用 5 秒间隔把账号捶热，确认活了以后每 30 分钟保活一次」，不用全程高频
  - 只对 Keepalive / Keepalive Once 生效；Recovery Monitor 全通即退出，不需要降速

```bash
# 每 10 秒发一次请求，跑完一轮就退出
REQUEST_INTERVAL_SEC=10 bash scripts/run-all.sh --once

# 恢复监控：每 60 秒轮询一轮（全部正常且响应 <30s 时仍会提前退出）
REQUEST_INTERVAL_SEC=60 MAX_DURATION_SEC=3600 bash scripts/monitor-recovery.sh

# Actions：Actions -> Run workflow -> interval 填 30
```

降速节奏也可以单独调：

```bash
# 快跑阶段 5 秒一次，第一次成功之后改成每 10 分钟保活一次
REQUEST_INTERVAL_SEC=5 SLOW_INTERVAL_MIN=10 bash scripts/run-all.sh

# 成功后也一直保持 5 秒一次（不降速）
REQUEST_INTERVAL_SEC=5 SLOW_INTERVAL_MIN=0 bash scripts/run-all.sh

# 只对 Keepalive / Keepalive Once 生效；Recovery Monitor 全通即退出
```

### 不会停止（自动续跑）

GitHub Actions 单个 job 最多跑 6 小时，这条限制只能绕，不能取消，所以「不停止」是这么实现的：

- 脚本自己**不再有 5 小时 58 分的自杀逻辑**：`MAX_DURATION_SEC` 默认 `0` = 不设上限，本地/自建 runner 可以一直跑，日志显示 `剩余: 无限`
- Actions 里由工作流给 `max_duration_sec`（默认 `21000` ≈ 5h50m）：每段跑到 5h50m 就发完报告正常收尾，紧接着用 `GITHUB_TOKEN` 调 workflow_dispatch **自动重新触发同一个工作流**，下一段接着跑——从外面看就是 24 小时不停
- 关掉续跑：触发时把 `auto_continue` 填 `false`，这一段跑完就真的结束（Keepalive 默认 `true`；Keepalive Once / Recovery Monitor 默认 `false`）
- `max_duration_sec` 填 `0` 也能「本段不设上限」，但 GitHub 会在 6 小时整硬杀 job，被杀掉的 job 不会再续跑（不推荐）
- ⚠️ **私有仓库的 Actions 分钟数**：私有仓库按套餐计分钟数（Free 套餐 2000 分钟/月），24/7 续跑约 43,200 分钟/月，很快就会超额；public 仓库不限分钟数

间隔越小请求越密集（例如 10 秒 + 6 小时容器 ≈ 2000 次请求），可能触发中转站限流或消耗额度；建议配合 `--once` 或告警阈值使用。


## 本地运行

### 本地单次测试

```bash
# 设置 token
export ANYROUTER_TOKENS="sk-ant-your-token-here"

# 运行单 token 测活
bash scripts/keepalive.sh "$ANYROUTER_TOKENS"
```

### 本地批量运行

```bash
# 方式 1：使用环境变量
export ANYROUTER_TOKENS="sk-ant-xxx111
sk-ant-xxx222"
export QQ_EMAIL="yourname@qq.com"
export QQ_SMTP_AUTH_CODE="your_auth_code"
bash scripts/run-all.sh

# 方式 2：使用 .env 文件
cp .env.example .env
# 编辑 .env 填入你的配置
bash scripts/run-all.sh
```

### 本地恢复监控

```bash
# 每 30 分钟轮询，全通且响应 <30s 自动退出
export ANYROUTER_TOKENS="sk-ant-xxx111
sk-ant-xxx222"
export QQ_EMAIL="yourname@qq.com"
export QQ_SMTP_AUTH_CODE="your_auth_code"
bash scripts/monitor-recovery.sh

# 调整轮询间隔和运行时长
POLL_INTERVAL=600 MAX_DURATION_SEC=3600 bash scripts/monitor-recovery.sh

# 每 60 秒发一次请求（固定间隔，不加抖动）
REQUEST_INTERVAL_SEC=60 MAX_DURATION_SEC=3600 bash scripts/monitor-recovery.sh
```

### 本地单次快速测试（跳过 50 分钟等待）

```bash
export ANYROUTER_TOKENS="sk-ant-test"
MAX_DURATION_SEC=60 bash scripts/run-all.sh
```

### 用 OpenAI 格式的模型测活（如 gpt-6-astra）

```bash
# 模型 id 不是 claude-*，自动切到 OpenAI Responses 协议（/v1/responses）
export ANYROUTER_TOKENS="sk-your-relay-key"

# 先查该站点支持哪些模型 id（任何 OpenAI 兼容站点都适用）
bash scripts/list-models.sh "$ANYROUTER_TOKENS"

# gpt-6-astra 是默认模型，直接跑就走 Responses 协议
bash scripts/keepalive.sh "$ANYROUTER_TOKENS"

# 或显式指定协议
PROTOCOL=responses MODEL="gpt-6-astra" bash scripts/keepalive.sh "$ANYROUTER_TOKENS"
PROTOCOL=openai MODEL="gpt-6-astra" bash scripts/keepalive.sh "$ANYROUTER_TOKENS"   # 旧 chat-completions 接口
PROTOCOL=anthropic MODEL="claude-opus-4-8[1m]" bash scripts/keepalive.sh "$ANYROUTER_TOKENS"

# 批量 / 恢复监控同样生效（MODEL、PROTOCOL 走环境变量）
MODEL="gpt-6-astra" bash scripts/run-all.sh --once
MODEL="gpt-6-astra" bash scripts/monitor-recovery.sh
```

## 运行测试

```bash
# 安装 bats（如果未安装）
npm install -g bats

# 运行测试
bats tests/
```

## 运行时序

### Keepalive

| 时区 | 启动时间 |
|---|---|
| UTC | 18:00 |
| 北京时间 (UTC+8) | 02:00 |

容器启动后内部每 50 分钟轮询一轮；每段约跑 5 小时 50 分钟，发完报告后自动续跑下一段（GitHub 单个 job 6 小时硬上限，见「不会停止（自动续跑）」）。

### Recovery Monitor

手动触发后每 **30 分钟** 轮询一轮。当全部 token 正常且最大响应时间 < 30 秒时自动提前退出。否则持续运行至 6 小时超时。

## 文件结构

```
├── .github/workflows/
│   ├── keepalive.yml              # 保活工作流（定时 + 手动）
│   ├── keepalive-once.yml         # 单次测活工作流（手动）
│   └── monitor-recovery.yml       # 恢复监控工作流（手动）
├── scripts/
│   ├── keepalive.sh               # 核心脚本：单 token 测活（Anthropic / OpenAI 双协议）
│   ├── list-models.sh             # 查看中转站实际支持的模型 id
│   ├── install-cli.sh             # 安装 Claude Code CLI / Codex CLI（已装则跳过）
│   ├── run-all.sh                 # 批量运行器：50 分钟轮询
│   ├── monitor-recovery.sh        # 恢复监控：30 分钟轮询 + 早期退出
│   ├── continue-workflow.sh       # 续跑：用 GITHUB_TOKEN 重新触发工作流，实现不停止
│   ├── prompts.txt                # 默认 prompt 池：20 条轻量探针
│   └── prompts-engineering.txt    # 备用 prompt 池：65 条工程提问
├── tests/
│   └── test_keepalive.bats        # BATS 测试套件
├── .env.example                   # 本地配置模板
└── README.md
```

## 注意事项

- **不要滥用**：保活仅凌晨低峰期运行，恢复监控按需手动触发，频率合理不会对 Anyrouter 造成压力
- **遵守条款**：请遵守 Anyrouter 的使用条款和服务协议
- **频率控制**：默认 token 之间间隔 30 秒（带随机抖动）；可用 `REQUEST_INTERVAL_SEC`（Actions 的 `interval`）改成固定间隔，间隔越短越容易被限流
- **成本**：每次测活只发一条随机短 prompt，单次成本极低；模型由 `MODEL` 决定，OpenAI 协议默认 `max_tokens=128`（可用 `MAX_TOKENS=none` 关闭）
- **邮箱配置**：QQ 邮箱的 SMTP 授权码请在 QQ 邮箱 → 设置 → 账号 → POP3/IMAP/SMTP 服务 中生成
- **邮件发不出去（QQ 回 `502 Invalid input from <IP>`）**：认证其实是成功的，被拒的是 `MAIL FROM` —— QQ 不信任 GitHub Actions 的机房 IP。实测 465/587 两个端口、带不带 `SIZE` 参数都一样，换端口没用。此时把 `SMTP_URL` 换成别的邮箱服务（`smtps://smtp.example.com:465`），或改用自建 runner（家宽/公司出口 IP）。排查用 `smtp_debug=true`（Actions 输入）打印完整 SMTP 会话：
  ```
  > AUTH LOGIN
  < 235 Authentication successful
  > MAIL FROM:<you@qq.com>
  < 502 Invalid input from 20.118.213.20 to newxmesmtplogicsvrsza73-0.qq.com.
  ```
- **Prompt 池**：默认 20 条轻量探针（`scripts/prompts.txt`），每次随机选一条；工程提问池在 `scripts/prompts-engineering.txt`，用 `PROMPTS_FILE` 切换
- **CLI 协议**：`anthropic` 走 Claude Code CLI、`codex` 走 Codex CLI；不确定装没装就先跑 `bash scripts/install-cli.sh codex`（已装会跳过）
- **Actions 分钟数**：不停止 = 24/7 占用 runner。私有仓库按套餐计分钟数（Free 套餐 2000 分钟/月），24/7 约 43,200 分钟/月，很快会超额；public 仓库不限。想省额度就把 `auto_continue` 填 `false`
