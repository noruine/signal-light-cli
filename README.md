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

首次运行会安装程序，之后可再次运行同一命令更新。更新会保留设备配对、灯效和开机启动设置，
并同步已接入 Agent 的 signal-light hooks；其他 hooks 不受影响。服务运行时会自动重启，已有会话状态会恢复。
已安装的程序也可运行 `signal-light upgrade` 更新。

## 开始使用

运行 `signal-light` 打开交互菜单，按提示配对设备、启动服务并接入 Agent。Codex 接入后，
还需在 Codex 中运行 `/hooks` 并确认信任，钩子才会生效。

服务默认不会在登录时自动启动；可在菜单的「服务」中开启开机启动。配对时请确认设备名称；
附近有多盏灯时，按名称或 UUID 选择。`--first` 仅在找到唯一设备时自动选择。

需要直接执行命令时：

| 用途 | 命令 |
| --- | --- |
| 查看状态、日志和诊断 | `signal-light status`、`signal-light logs`、`signal-light doctor` |
| 管理后台服务 | `signal-light service start`、`signal-light service stop`、`signal-light service restart` |
| 配对和校准设备 | `signal-light pair`、`signal-light unpair`、`signal-light calibrate` |
| 管理灯效和亮度 | `signal-light config` |
| 管理 Agent 钩子 | `signal-light hooks install`、`signal-light hooks status`、`signal-light hooks uninstall` |
| 检查和更新固件 | `signal-light firmware check`、`signal-light firmware update` |
| 更新或卸载程序 | `signal-light upgrade`、`signal-light uninstall` |

完整命令说明见 `signal-light --help`；子命令帮助见 `signal-light <命令> --help`。

## 灯光状态

| 状态 | 默认灯效 | 含义 |
| --- | --- | --- |
| 空闲 | 绿色呼吸 | 没有正在处理任务的会话 |
| 工作中 | 黄色闪烁 | Agent 正在处理任务 |
| 等待审批 | 黄红呼吸 | Agent 正在等待权限确认 |
| 等待回答 | 黄绿呼吸 | Agent 正在等待你的回答 |

多个会话同时存在时，信号灯显示优先级最高的状态：等待审批、等待回答、工作中、空闲。
运行 `signal-light status` 可查看各状态的会话数；交互菜单中的状态页会持续刷新。
可在交互菜单中调整灯效和亮度。关闭灯光不会停止后台服务。

钩子只转发会话状态，不处理审批或回答；连接服务和等待回执各有两秒超时，超时后静默退出。
卸载会清理 signal-light 的程序、配置、运行数据、socket 和 hooks；正常完成后不留 signal-light
自有残留。其他 hooks 和配置保持不变。单项清理失败不会中断
卸载，命令会继续处理并报告未清理项。非交互环境运行 `signal-light uninstall` 时需加 `--yes` 确认。

事件映射、多会话状态和过期规则见[桥接协议文档](docs/bridge.md)。

## 固件

运行 `signal-light firmware check` 检查固件，运行 `signal-light firmware update` 更新。
默认从 [open-vibe-island](https://github.com/itdragons/open-vibe-island) 的 `wg` 分支获取固件清单；
也可用 `--file` 指定本地固件文件。更新期间服务会暂时停止，请勿断电或退出程序。

## 文件位置

| 内容 | 位置 |
| --- | --- |
| 程序数据、配对信息、设置和日志 | `~/.signal-light/` |
| 命令入口 | `~/.local/bin/signal-light` |
| 后台服务配置 | `~/Library/LaunchAgents/app.signal-light.daemon.plist` |

卸载只删除 signal-light 创建的文件和链接。

## 从源码构建

项目使用 Swift tools 6.2，构建需要 Swift 6.2 或更高版本。

- `make build`：构建程序。
- `make test`：运行测试。
- `make lint`：检查格式、SwiftLint 规则和 CLI 文案；需要 `swiftformat` 与 `swiftlint`。

模块划分和开发约定见 [AGENTS.md](AGENTS.md)。
