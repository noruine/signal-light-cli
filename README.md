# signal-light

`signal-light` 用于在 macOS 上配对和控制 ESP32-C3 三色信号灯。接入 Agent 后，
信号灯会显示会话状态。目前支持：

1. Claude Code
2. Codex

需要 macOS 14 或更高版本。

信号灯只显示状态；审批和回答仍在 Agent 自己的界面中完成。

## 安装

在仓库目录运行：

```sh
make install
```

此命令会构建并安装当前版本。首次运行会安装，以后可用同一命令更新。更新会保留
配对信息、灯效配置和开机启动设置；只有后台服务正在运行时，才会重启以加载新版本。

从已安装的程序运行 `signal-light upgrade`，会检查安装时记录的源码仓库；有改动时，
程序会询问是否更新。从仓库更新时，运行 `make install` 即可。

## 首次使用

按顺序完成配对、启动服务和接入 Agent：

```sh
signal-light pair
signal-light service start
signal-light hooks install
```

- 配对时请确认设备名称。附近有多盏灯时，请按名称或 UUID 选择。`--first` 只在扫描到
  唯一设备时才会自动选择；非交互环境请用 `--device` 指定设备。
- `signal-light service start` 会启动后台服务，但不会设置登录时自动启动。需要自动启动时，
  再运行 `signal-light service autostart enable`。
- 在交互终端中运行 `signal-light hooks install` 会显示 Agent 选择界面；也可以直接指定
  `claude` 或 `codex`。
- Codex 首次接入后，还需在 Codex 中运行 `/hooks` 并确认信任，钩子才会生效。

直接运行 `signal-light` 可打开交互菜单。常用命令如下：

- 查看状态、日志、诊断或文件清单：`signal-light status`、`signal-light logs`、
  `signal-light doctor`、`signal-light audit`。
- 启动、停止或重启服务：`signal-light service start`、`signal-light service stop`、
  `signal-light service restart`。
- 设置登录时自动启动：`signal-light service autostart enable`、
  `signal-light service autostart disable`、`signal-light service autostart status`。
- 配对、解除配对或校准接线：`signal-light pair`、`signal-light unpair`、
  `signal-light calibrate`。
- 查看或修改设备名称：`signal-light rename`；带上新名称即可修改。
- 查看或修改灯效：`signal-light config`、`signal-light config set`、
  `signal-light config brightness`。
- 接入、查看或移除 hooks：`signal-light hooks install`、`signal-light hooks status`、
  `signal-light hooks uninstall`。
- 检查或更新固件：`signal-light firmware check`、`signal-light firmware update`。
- 升级或卸载程序：`signal-light upgrade`、`signal-light uninstall`。
- 配置固定签名：`signal-light sign`。它会把签名身份写入登录钥匙串并重新签名已安装
  程序；服务运行时会重启，macOS 会再次请求蓝牙权限。此后更新可沿用同一签名。

其他命令和参数见 `signal-light --help`，或运行 `signal-light <命令> --help`。

## 灯的状态

| 状态 | 默认灯效 | 含义 |
| --- | --- | --- |
| 空闲 | 绿色呼吸 | 当前没有运行中的会话 |
| 运行中 | 黄色闪烁 | 会话开始或提交了新提示 |
| 等待审批 | 黄红呼吸 | Agent 正在请求权限 |
| 等待回答 | 黄绿呼吸 | Agent 正在等待你的回答 |

多个会话同时运行时，显示优先级为：等待审批、等待回答、运行中、空闲。可以在菜单
中修改灯效和亮度，也可以用 `signal-light config set` 或
`signal-light config brightness` 调整。关闭信号灯总开关不会停止后台服务。

## 接入 Agent

安装时只配置驱动灯态所需的事件：

支持的事件：

- Claude Code：`SessionStart`、`UserPromptSubmit`、`PermissionRequest`、`Stop`、
  `StopFailure`、`SessionEnd`。
- Codex：`SessionStart`（启动、恢复、清空、压缩后继续）、`UserPromptSubmit`、
  `PermissionRequest`、`Stop`、`SessionEnd`、`Interrupt`。

安装和卸载只会修改 signal-light 自己添加的 hooks，不会改动其他配置。重复安装不会
重复添加。hooks 只转发会话事件，不处理审批，也不会阻塞 Agent。

卸载本程序时，Agent 配置默认保留。交互操作时可以选择同时移除 signal-light 写入的
hooks；脚本中使用 `signal-light uninstall --yes --remove-hooks`。

钩子协议和状态映射见 [docs/bridge.md](docs/bridge.md)。

## 固件更新

运行 `signal-light firmware check` 检查版本，运行 `signal-light firmware update` 更新。
默认从项目维护的固件清单下载对应设备的固件，也可以用 `--file` 指定本地文件。
更新时后台服务会暂时停止，完成后恢复；过程中不要断电或关闭程序。

固件由 [open-vibe-island](https://github.com/itdragons/open-vibe-island) 仓库的
`wg` 分支维护。CLI 从该项目的版本清单获取版本和下载地址。

## 问题排查

- 配对前请确认选中的是自己的灯。附近可能有其他设备；扫描到多盏时按名称或 UUID 选择。
- 灯没有响应时，依次运行 `signal-light status`、`signal-light doctor` 和
  `signal-light logs`，检查设备连接、配置和服务日志。
- Agent 事件没有反映到灯上时，运行 `signal-light hooks status` 检查 hooks 是否已安装；
  Codex 还需完成 `/hooks` 信任确认。
- 单次运行中跳过 hooks，可设置环境变量 `SIGNAL_LIGHT_SKIP_HOOKS=1`。

## 文件位置

| 内容 | 位置 |
| --- | --- |
| 程序、配对信息、设置和日志 | `~/.signal-light/` |
| 命令入口 | `~/.local/bin/signal-light` |
| 后台服务配置 | `~/Library/LaunchAgents/app.signal-light.daemon.plist` |
| Agent 与守护进程之间的 socket | `~/.signal-light/bridge.sock` |

卸载只删除 signal-light 自己创建的文件和链接，其他文件会保留。

## 从源码构建

项目使用 Swift tools 6.2，构建时需要 Swift 6.2 或更高版本。

- `make build`：构建程序。
- `make test`：运行测试。
- `make lint`：检查格式、SwiftLint 规则和 CLI 文案；需要安装 `swiftformat`、`swiftlint`。

模块边界和开发约定见 [AGENTS.md](AGENTS.md)。
