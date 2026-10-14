# Bridge：事件与会话状态

`agent-hooks` 读取 Agent 发来的 hook JSON，将其映射为统一的 `HookEvent`，再通过 Unix socket
发送给守护进程。守护进程只处理统一事件，不解析 Claude Code 或 Codex 的原始格式。

## 事件传递

每次 hook 建立一条 socket 连接并发送一行 JSON。守护进程应用事件后回一行
`{"ok":true}` 并关闭连接；收到回执表示事件已交给会话状态机处理。连接服务和等待回执各有两秒超时；
服务不可用或超时都会静默退出。

```json
{
  "version": 1,
  "source": "claude",
  "kind": "PermissionRequest",
  "sessionID": "…",
  "isQuestion": false
}
```

| 字段 | 含义 |
| --- | --- |
| `version` | 协议版本。未知版本不会改变会话状态。 |
| `source` | Agent 来源：`claude` 或 `codex`。 |
| `kind` | 归一化后的事件类型。 |
| `sessionID` | Agent 会话 ID；会与来源一起组成会话标识。 |
| `isQuestion` | 仅 `PermissionRequest` 使用。`true` 表示等待回答；否则表示等待审批。 |

## Agent 事件映射

| Agent hook | 归一化事件 | 说明 |
| --- | --- | --- |
| Claude `SessionStart` | `SessionStart` | 开始或恢复会话。当前未按启动原因筛选；包括 `compact` 在内的每次触发都会把会话设为空闲。 |
| Claude `UserPromptSubmit` | `UserPromptSubmit` | 开始处理新提示。 |
| Claude `PermissionRequest` | `PermissionRequest`，`isQuestion: false` | 等待审批。 |
| Claude `PreToolUse`（`AskUserQuestion`） | `PermissionRequest`，`isQuestion: true` | 等待用户回答。其他 `PreToolUse` 忽略。 |
| Claude `PostToolUse` / `PostToolUseFailure` | `PostToolUse` | 工具结束后继续记为运行中。 |
| Claude `Stop` / `StopFailure` | `Stop` / `StopFailure` | 当前轮次结束。 |
| Claude `SessionEnd` | `SessionEnd` | 移除会话。 |
| Codex `SessionStart`（startup、resume、clear） | `SessionStart` | 初始化、恢复或清空会话时触发。 |
| Codex `UserPromptSubmit` | `UserPromptSubmit` | 开始处理新提示。 |
| Codex `PermissionRequest` | `PermissionRequest`，`isQuestion: false` | 等待审批。 |
| Codex `PostToolUse` | `PostToolUse` | 工具结束后继续记为运行中。 |
| Codex `Stop` / `Interrupt` | `Stop` / `Interrupt` | 当前轮次结束或中断。 |
| Codex `SessionEnd` | `SessionEnd` | 移除会话。 |

Claude 子代理事件会忽略，避免把同一工作重复计入。Codex.app 没有 transcript 的内部事件也会忽略。
Codex 的 `compact` 不作为新会话处理；压缩后可能继续当前轮次。

## 会话状态与灯光汇总

状态按 `source + sessionID` 分开维护，因此不同 Agent 的相同会话 ID 不会冲突。

| 归一化事件 | 会话状态 |
| --- | --- |
| `SessionStart` | 空闲 |
| `UserPromptSubmit` / `PostToolUse` | 运行中 |
| `PermissionRequest`，`isQuestion: false` | 等待审批 |
| `PermissionRequest`，`isQuestion: true` | 等待回答 |
| `Stop` / `StopFailure` / `Interrupt` | 空闲 |
| `SessionEnd` | 移除会话 |

一盏灯无法分别显示多个会话，因此守护进程会汇总所有会话，只显示优先级最高的一种状态：
**等待审批 > 等待回答 > 运行中 > 空闲**。空闲会话不影响其他会话。

| 会话 A | 会话 B | 灯显示 |
| --- | --- | --- |
| 运行中 | 空闲 | 运行中 |
| 运行中 | 等待回答 | 等待回答 |
| 等待回答 | 等待审批 | 等待审批 |
| 运行中 | 结束或移除 | 运行中 |

每个事件只更新它所属的会话，然后重新计算整盏灯的状态。因此，一个会话结束、变空闲或被移除时，
如果还有其他活动会话，灯会显示它们中优先级最高的状态。

运行中状态在两小时没有新事件后过期；等待审批和等待回答在 24 小时没有新事件后过期。
守护进程每 30 秒检查过期状态。会话状态只保存在守护进程内存中；服务重启后，已有会话不会自动恢复，需等 Agent 发来下一条 hook 事件。

## 安装范围

Claude Code 安装 `SessionStart`、`UserPromptSubmit`、`PreToolUse`（仅匹配
`AskUserQuestion`）、`PermissionRequest`、`PostToolUse`、`PostToolUseFailure`、`Stop`、
`StopFailure` 和 `SessionEnd`。

Codex 安装 `SessionStart`（startup、resume、clear）、`UserPromptSubmit`、
`PermissionRequest`、`PostToolUse`、`Stop`、`SessionEnd` 和 `Interrupt`。

安装和卸载只修改 signal-light 自己写入的 hook。单次子进程可通过
`SIGNAL_LIGHT_SKIP_HOOKS=1` 跳过转发。
