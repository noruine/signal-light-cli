# Bridge：事件与会话状态

`agent-hooks` 读取 Agent 发来的钩子 JSON，将其映射为统一的 `HookEvent`，再通过 Unix 套接字
发送给守护进程。守护进程只处理统一事件，不解析 Claude Code 或 Codex 的原始格式。

## 事件传递

每次钩子运行时建立一条 Unix 套接字连接，并发送一行 JSON。守护进程按连接接收顺序应用事件，完成后回一行
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

| Agent 钩子 | 归一化事件 | 说明 |
| --- | --- | --- |
| Claude `SessionStart`（startup、resume、clear、fork） | `SessionStart` | 开始或恢复会话；signal-light 的匹配规则不处理 `compact`，映射层也会忽略该原因。 |
| Claude `UserPromptSubmit` | `UserPromptSubmit` | 开始处理新提示。 |
| Claude `PermissionRequest` | `PermissionRequest`，`isQuestion: false` | Claude Code 为工具请求权限时触发，显示等待审批。 |
| Claude `PermissionDenied` | `PostToolUse` | 自动模式拒绝工具后，清除等待审批并继续显示工作中。 |
| Claude `PreToolUse`（`AskUserQuestion`） | `PermissionRequest`，`isQuestion: true` | 等待用户回答。其他 `PreToolUse` 忽略。 |
| Claude `Elicitation` | `PermissionRequest`，`isQuestion: true` | MCP 服务请求用户输入，显示等待回答；hook 不返回处理结果，保留 Claude Code 的交互对话框。 |
| Claude `ElicitationResult` | `PostToolUse` | 用户已提交或取消输入，恢复为工作中。 |
| Claude `PostToolUse` / `PostToolUseFailure` | `PostToolUse` | 工具结束后继续记为工作中。 |
| Claude `Stop` / `StopFailure` | `Stop` / `StopFailure` | 当前轮次结束。 |
| Claude `SessionEnd` | `SessionEnd` | 移除会话。 |
| Codex `SessionStart`（startup、resume、clear、fork） | `SessionStart` | 初始化、恢复、清空或分叉会话时触发；映射层忽略 `compact`。 |
| Codex `UserPromptSubmit` | `UserPromptSubmit` | 开始处理新提示。 |
| Codex `PermissionRequest` | 忽略 | 官方定义为即将请求审批；但 hook 先于自动审查执行，后续可能自动批准。仅凭该事件不能确认用户正在等待，因此不用于灯态。 |
| Codex `PreToolUse` | `PreToolUse` | 工具开始执行，显示工作中。 |
| Codex `PostToolUse` | `PostToolUse` | 工具结束后继续记为工作中。 |
| Codex `Stop` / `Interrupt` | `Stop` / `Interrupt` | 当前轮次结束或中断。 |
| Codex `SessionEnd` | `SessionEnd` | 移除会话。 |

Claude 子代理事件不会安装，也会在映射层忽略，避免把同一工作重复计入。Codex 的子代理事件使用父会话 ID，
同样不单独安装。Codex.app 没有会话记录的内部事件会忽略。Claude Code 和 Codex 的 `compact` 都不会作为新会话处理；
压缩后可能继续当前轮次，因此保留原会话状态。

## 会话状态与灯光汇总

状态按 `source + sessionID` 分开维护，因此不同 Agent 的相同会话 ID 不会冲突。

| 归一化事件 | 会话状态 |
| --- | --- |
| `SessionStart` | 空闲 |
| `UserPromptSubmit` / `PreToolUse` / `PostToolUse` | 工作中 |
| Claude `PermissionRequest`，`isQuestion: false` | 等待审批 |
| `PermissionRequest`，`isQuestion: true` | 等待回答 |
| `Stop` / `StopFailure` / `Interrupt` | 空闲 |
| `SessionEnd` | 移除会话 |

一盏灯无法分别显示多个会话，因此守护进程会汇总所有会话，只显示优先级最高的一种状态：
**等待审批 > 等待回答 > 工作中 > 空闲**。空闲会话不影响其他会话。`signal-light status`
和交互菜单只显示灯当前状态，不列出会话数量；交互菜单每秒刷新一次状态。

| 会话 A | 会话 B | 灯显示 |
| --- | --- | --- |
| 工作中 | 空闲 | 工作中 |
| 工作中 | 等待回答 | 等待回答 |
| 等待回答 | 等待审批 | 等待审批 |
| 工作中 | 结束或移除 | 工作中 |

每个事件只更新所属会话，然后重新计算整盏灯的状态。因此，一个会话结束、变为空闲或被移除时，
如果还有其他活动会话，灯会显示其中优先级最高的状态。

工作中状态在两小时没有新事件后转为空闲；等待审批和等待回答在 24 小时没有新事件后转为空闲。守护进程在最近一条会话记录到期时检查状态，空闲记录最多保留 24 小时；没有会话时不轮询。会话状态和最后事件时间保存在 signal-light 自己的 `state.json` 中，服务重启后会恢复，并继续按上述规则过期。

## 安装范围

Claude Code 安装 `SessionStart`、`UserPromptSubmit`、`PreToolUse`（仅匹配
`AskUserQuestion`）、`PermissionRequest`、`Elicitation`、`ElicitationResult`、
`PermissionDenied`、`PostToolUse`、`PostToolUseFailure`、`Stop`、`StopFailure` 和
`SessionEnd`。

Codex 安装 `SessionStart`（startup、resume、clear、fork）、`UserPromptSubmit`、
`PreToolUse`、`PostToolUse`、`Stop`、`SessionEnd` 和 `Interrupt`。Codex 官方把
[`PermissionRequest`](https://developers.openai.com/codex/hooks) 定义为即将请求审批，但该 hook 可能先于自动审查结果；
自动审查随后可能批准。cmux 也把该事件作为非阻塞遥测处理，只有 Codex app-server 通道能取得审查后的可操作审批请求。
因此 signal-light 不据此显示等待审批。Claude Code 的 `PermissionRequest` 则用于显示等待审批。

Claude Code 的 `Notification` 不改变会话状态，审批直接由 `PermissionRequest` 表示，因此不重复安装通知事件。
所有 signal-light hook 的执行超时为 5 秒；Codex 的 `SessionEnd` 和 `Interrupt` 最长为 3 秒。

事件行为以 [Claude Code hooks 文档](https://code.claude.com/docs/en/hooks)、
[Codex hooks 文档](https://developers.openai.com/codex/hooks) 和
[cmux Feed 设计](https://github.com/manaflow-ai/cmux/blob/main/docs/feed.md) 为准。

安装或升级只同步当前事件清单中的 signal-light hooks；清单外的事件和第三方 hooks 保持不变。
卸载会扫描所有事件，只移除命令与 signal-light 安装记录匹配的 hooks。

安装和卸载只修改 signal-light 自己写入的钩子。
