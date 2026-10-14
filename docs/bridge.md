# 钩子协议与状态映射

Agent 的钩子由 `agent-hooks` 转发：它从 stdin 读到 Agent 的钩子 JSON，
归一化成一条 `HookEvent`，通过 Unix socket 发给守护进程。守护进程不解析任何
Agent 原始格式——两个 Agent 的差异只存在于转发程序里。

## 线格式

一条连接、一条消息、一行 JSON；守护进程先记下事件，再回一行
`{"ok":true}` 并关闭连接——收到回执即代表消息已进入状态机。

```json
{
  "version": 1,
  "source": "claude",
  "kind": "PermissionRequest",
  "sessionID": "…",
  "isQuestion": false
}
```

| 字段 | 说明 |
| --- | --- |
| `version` | 协议版本；守护进程丢弃不认识的版本，不猜测语义 |
| `source` | `claude` / `codex` |
| `kind` | 事件名（见下表） |
| `sessionID` | Agent 自己的会话 id；不同 `source` 之间不会串 |
| `isQuestion` | 仅 `PermissionRequest` 用：Claude 的 `AskUserQuestion` 是提问，不是审批 |

## 事件 → 状态

| 事件 | 状态 | 说明 |
| --- | --- | --- |
| `SessionStart` | 空闲 | 新会话，尚未干活 |
| `UserPromptSubmit` | 运行中 | 提交了提示词 |
| `PermissionRequest`（工具） | 等待审批 | |
| `PreToolUse`（`AskUserQuestion`） | 等待回答 | |
| `PostToolUse` / `PostToolUseFailure` / `UserPromptSubmit` | 运行中 | 问题已回答或审批后的工具已执行 |
| `Stop` / `StopFailure` / `Interrupt` | 空闲 | 一轮或一次会话结束 |
| `SessionEnd` | 移除该会话 | |

`running` 超过 2 小时没有更新、等待审批/回答超过 24 小时，会按空闲处理。
Agent 异常退出时不会补发结束事件，因此守护进程每 30 秒重新检查过期状态。

灯的颜色取所有会话里最高的那一档：**等待审批 > 等待回答 > 运行中 > 空闲**。

## 安装的钩子

| Agent | 事件 |
| --- | --- |
| Claude Code | `SessionStart` `UserPromptSubmit` `PreToolUse`（`AskUserQuestion`）`PermissionRequest` `PostToolUse` `PostToolUseFailure` `Stop` `StopFailure` `SessionEnd` |
| Codex | `SessionStart`（覆盖 startup/resume/clear）`UserPromptSubmit` `PermissionRequest` `PostToolUse` `Stop` `SessionEnd` `Interrupt` |

Codex 的 `compact` 会在一轮工作中触发；压缩完成后会立即继续当前轮次，
因此不把它当作新的空闲会话处理。

- 转发程序不向 stdout 写任何内容，因此不会替 Agent 做决定：审批与提问仍由
  Agent 自己的界面处理。
- 安装只动本工具写入的条目，其它工具（claude-island、cmux 等）的钩子原样保留。
- 单次子进程跳过钩子：设置 `SIGNAL_LIGHT_SKIP_HOOKS=1`。
