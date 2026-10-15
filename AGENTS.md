# AGENTS.md

用户安装与使用说明见 [README.md](README.md)；钩子协议、事件映射和会话状态见
[`docs/bridge.md`](docs/bridge.md)。同一说明只在所属文档维护，避免复制。
项目说明文档统一使用中文；标识符、源码注释、日志和文档注释使用英语；命令与协议字段保留原文。

## 项目结构

- `Sources/SignalLightKit`：BLE、灯效与设置、会话注册表、桥接协议和 Agent 钩子安装器；
  不放 CLI 或界面代码。
- `Sources/SignalLightCLICore`：命令、交互菜单和守护进程运行逻辑。`run` 是守护进程入口。
- `Sources/SignalLightCLI`：供测试导入 CLI 核心的轻量 `@main` 入口。
- `Sources/SignalLightHooks`：读取 Agent 钩子输入并转发事件的独立程序。
- `Tests/SignalLightKitTests`：覆盖状态机、协议、映射和存储等核心行为。
- `Tests/SignalLightCLITests`：覆盖 CLI 文案、交互布局和会话重试策略。

## 开发与验证

| 任务 | 命令 |
| --- | --- |
| 构建 | `make build` |
| 安装或升级本机版本 | `make install` |
| 运行测试 | `make test` |
| 格式化 | `make format` |
| 检查格式、SwiftLint 和 CLI 文案 | `make lint` |

`make build` 和 `make test` 会通过脚本传入 `--build-system native`。Command Line Tools 环境下，
优先使用 `make test` 或 `scripts/test.sh`；后者会补充 `Testing.framework` 搜索路径。
格式和 lint 命令需要通过 Homebrew 安装 `swiftformat` 与 `swiftlint`。

## 硬件与系统操作

任何打开 BLE 的操作都会暂停用户正在运行的守护进程，并连接真实设备。

- 只有用户明确要求时才配对、改名、校准或刷写固件。附近可能有多盏灯时，
  不要传入 `--first`；程序不会猜选设备。
- 测试期间不要运行 `service stop`、`service restart` 或 `unpair`。
- `make install`、`upgrade` 和 `sign` 会在守护进程运行时重启它；不要在自动检查或无关测试中调用。
- 使用临时主目录测试时，仍会共享真实用户的 launchd 标签。隔离测试必须设置独立的
  `SIGNAL_LIGHT_LAUNCHD_LABEL`；否则临时卸载或停止可能影响真实服务。
  `SIGNAL_LIGHT_HOOKS_BINARY` 用于隔离钩子程序路径。
- 若进程在操作中被强制终止，守护进程可能保持停止状态；恢复方式是运行 `signal-light service start`，并告知用户。

硬件无关的端到端检查（要求守护进程已运行）：

```bash
echo '{"hook_event_name":"UserPromptSubmit","session_id":"smoke","cwd":"/tmp"}' \
  | .build/release/agent-hooks --source claude
.build/release/signal-light status   # 状态应变为运行中
echo '{"hook_event_name":"Stop","session_id":"smoke","cwd":"/tmp"}' \
  | .build/release/agent-hooks --source claude
```

## 实现约定

- 使用 Swift 6 严格并发模式。优先采用 actor 和值类型；使用 `@unchecked Sendable` 时，
  必须说明其线程安全依据，例如锁、队列、actor 或线程安全的存储类型。
- 面向用户的 CLI 文案使用自然中文。
- CLI 文案遵守 `scripts/check-cli-copy.sh`：使用书面表达和统一按键名称
  （Enter / Space / ↑/↓ / Esc）；操作标题带对应图标；只承诺确实会发生的行为。
  结果用语统一为“已X”“X完成”“X失败”“无法X”“已取消X”。从确认问题返回时不额外输出；
  取消正在执行的操作时输出一行后返回。只有确有结果需要阅读时才等待按键。
- 交互页面统一通过 `ScreenLayout` 渲染，顺序为面包屑、空行、上下文、空行、正文、空行、
  按键栏，且只有页脚使用弱化样式。菜单面包屑和按键栏分别通过
  `Terminal.menuBreadcrumb`、`Terminal.keyBar` 生成；独立 CLI 命令保持普通终端输出，
  不带菜单路径。页面只列出自己响应的按键。`make lint` 会检查过时的提示写法。
- 会写文件、钥匙串或 launchd 的行为，必须来自用户输入的命令，或在执行前明确说明并取得用户确认。
- 输出结果写到 stdout，进度和警告写到 stderr，确保管道输出可用。
- 根目录 `VERSION` 使用 `0.Y.Z`。每次提交若改动已发布代码（`Sources/`、`Makefile`、
  `Package.swift`），须在同一提交递增 Z。只有用户指定里程碑时才递增 Y，并将 Z 归零。
  文档、测试和工具改动不调整版本号。版本号只用于显示；变更检测比较源码戳。
  项目不创建发行版或标签。

## Git 提交约定

- 每轮改动文件后，在当前分支创建一个只包含同一主题的提交。
- 提交标题格式为 `type(scope): what and why`，不超过 72 字符；除专名和缩写
  （如 `macOS`、`CLI`、`Bluetooth`）外使用小写。类型限于 `feat`、`fix`、`docs`、
  `chore`、`refactor`、`test`、`style`。
- 仅当差异本身不足以说明原因时添加正文。正文用 `-` 列表说明原因，不写文件清单或改动流水账；每行不超过 72 字符。
- 不添加署名行。未经用户要求，不推送、打标签或创建合并请求。
