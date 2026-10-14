# signal-light

用终端管理 ESP32-C3 三色信号灯，也可以让它显示 AI Agent 的会话状态。
灯只负责提示；审批和回答仍在 Agent 中进行。

支持的 Agent：

1. Claude Code
2. Codex

需要 macOS 14 或更高版本。

## 安装

在项目仓库中运行：

```sh
make install
```

首次运行会安装程序，之后运行同一命令即可更新。更新会保留设备配对、灯效和开机启动设置；
如果后台服务正在运行，安装程序会重启它以加载新版本。重启后，进行中的 Agent 会话状态会清空，
等 Agent 发来下一条事件后再恢复显示。
已安装的程序也可运行 `signal-light upgrade` 检查安装时记录的源码仓库；从仓库更新时运行 `make install`。

## 开始使用

依次配对信号灯、启动服务并接入 Agent：

```sh
signal-light pair
signal-light service start
signal-light hooks install
```

- 配对时确认设备名称。附近有多盏灯时，请按名称或 UUID 选择；`--first` 只会在找到唯一设备时自动选择。
- 服务默认不会在登录时自动启动。需要时运行 `signal-light service autostart enable`。
- 在交互终端中，hooks 安装命令会让你选择 Agent；也可以指定 `claude` 或 `codex`。
- Codex 接入后，在 Codex 中运行 `/hooks` 并确认信任，钩子才会生效。

直接运行 `signal-light` 可打开交互菜单。常用命令：

| 用途 | 命令 |
| --- | --- |
| 查看状态、日志和诊断 | `signal-light status`、`signal-light logs`、`signal-light doctor` |
| 管理后台服务 | `signal-light service start`、`signal-light service stop`、`signal-light service restart` |
| 配对和校准设备 | `signal-light pair`、`signal-light unpair`、`signal-light calibrate` |
| 管理灯效和亮度 | `signal-light config` |
| 管理 Agent hooks | `signal-light hooks install`、`signal-light hooks status`、`signal-light hooks uninstall` |
| 检查和更新固件 | `signal-light firmware check`、`signal-light firmware update` |
| 更新或卸载程序 | `signal-light upgrade`、`signal-light uninstall` |

完整命令说明见 `signal-light --help`，子命令帮助见 `signal-light <命令> --help`。

## 灯光状态

| 状态 | 默认灯效 | 含义 |
| --- | --- | --- |
| 空闲 | 绿色呼吸 | 没有运行中的会话 |
| 运行中 | 黄色闪烁 | Agent 正在处理任务 |
| 等待审批 | 黄红呼吸 | Agent 正在等待权限确认 |
| 等待回答 | 黄绿呼吸 | Agent 正在等待你的回答 |

多个会话同时存在时，信号灯显示优先级最高的状态：等待审批、等待回答、运行中、空闲。
运行 `signal-light status` 或在交互菜单查看状态时，可看到各状态的会话数，以及当前灯态由哪些会话决定。
可在交互菜单中调整灯效和亮度。关闭灯光不会停止后台服务。

hooks 只转发会话状态，不处理审批或回答；连接服务和等待回执各有两秒超时，超时后静默退出。
安装和卸载只修改 signal-light 自己添加的配置。卸载程序时 hooks 默认保留；需要一起移除时，使用
`signal-light uninstall --yes --remove-hooks`。

事件映射、多会话状态和过期规则见 [Bridge 文档](docs/bridge.md)。

## 固件

运行 `signal-light firmware check` 检查固件，运行 `signal-light firmware update` 更新。
默认从 [open-vibe-island](https://github.com/itdragons/open-vibe-island) 的 `wg` 分支获取固件清单；
也可用 `--file` 指定本地固件文件。更新期间服务会暂时停止，请勿断电或退出程序。

## 问题排查

- 灯没有响应：运行 `signal-light status`、`signal-light doctor` 和 `signal-light logs` 检查连接与服务。
- Agent 状态没有显示：运行 `signal-light hooks status`；Codex 还需在 `/hooks` 中确认信任。
- 单次运行中跳过 hooks：设置环境变量 `SIGNAL_LIGHT_SKIP_HOOKS=1`。

## 文件位置

| 内容 | 位置 |
| --- | --- |
| 程序数据、配对信息、设置和日志 | `~/.signal-light/` |
| 命令入口 | `~/.local/bin/signal-light` |
| 后台服务配置 | `~/Library/LaunchAgents/app.signal-light.daemon.plist` |
| Agent 与服务之间的 socket | `~/.signal-light/bridge.sock` |

卸载只删除 signal-light 创建的文件和链接。

## 从源码构建

项目使用 Swift tools 6.2，构建需要 Swift 6.2 或更高版本。

- `make build`：构建程序。
- `make test`：运行测试。
- `make lint`：检查格式、SwiftLint 规则和 CLI 文案；需要 `swiftformat` 与 `swiftlint`。

模块划分和开发约定见 [AGENTS.md](AGENTS.md)。
