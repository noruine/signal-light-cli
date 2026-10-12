# signal-light

红绿灯（ESP32-C3）的命令行驱动：不用开 App，在终端里配对、调灯效、跑后台服务，
让 Claude Code / Codex 的会话状态直接体现在实体灯上。macOS 14 起。

- **两个可执行文件**：`signal-light`（CLI + 守护进程）、`signal-light-hooks`（Agent 钩子转发）。
- **一个库**：`SignalLightKit`（BLE、灯效模型、会话状态、钩子协议）。
- **没有 UI，也不接管审批**：权限弹窗和提问留在 Agent 自己的终端里，灯只做提示。

## 快速开始

```bash
make install                # 构建并安装（make help 看全部入口）
signal-light pair           # 扫描 → 选中你的灯（多盏时务必看清名字）
signal-light service start  # 启动后台服务（launchd）
signal-light hooks install  # 接入 Claude Code / Codex（勾选界面）
signal-light                # 不带参数进交互菜单
```

只装 CommandLineTools 的机器用 `make` 即可（它带上 `--build-system native`；
直接 `swift build` 需要自己加）。之后新开终端直接敲 `signal-light`。

## 命令

| 命令 | 作用 |
| --- | --- |
| `install` / `uninstall` | 安装到本机 / 卸载（可一并移除 Agent 钩子） |
| `pair` / `unpair` | 配对红绿灯 / 忘掉已配对设备（会先停服务） |
| `service start\|stop\|restart\|autostart` | 后台服务与开机自启 |
| `hooks install\|status\|uninstall` | 接入 / 查看 / 移除 Claude Code、Codex 钩子 |
| `config` | 各状态的灯效、全局亮度、总开关 |
| `calibrate` | 接线校准：逐个点亮引脚，记下红/黄/绿接在哪 |
| `firmware check\|update` | 检查新固件 / OTA 升级（升级中按 Ctrl-C 可取消） |
| `rename` | 改灯的蓝牙广播名称 |
| `status` / `logs` / `doctor` / `audit` | 状态、日志、体检、安装残留检查 |

## 架构

```
Agent 钩子 ──stdin JSON──▶ signal-light-hooks ──Unix socket──▶ 守护进程
                                                              │  SessionRegistry
                                                              ▼
                                                        灯效（BLE）
```

- `Sources/SignalLightKit` — 产品核心：BLE 会话、灯效与设置、会话状态机、钩子协议（`Bridge/`）、Agent 安装器。
- `Sources/SignalLightCLI` — 命令与交互菜单；`run` 子命令即守护进程本体。
- `Sources/SignalLightHooks` — 单文件转发程序，做完就退出，不阻塞 Agent。
- 钩子协议与状态映射：[docs/bridge.md](docs/bridge.md)；使用说明：[docs/cli.zh-CN.md](docs/cli.zh-CN.md)。

## 磁盘布局

| 内容 | 位置 |
| --- | --- |
| 程序与数据 | `~/.signal-light/`（`bin/`、`device.json`、`settings.json`、`state.json`、日志） |
| 命令 | `~/.local/bin/signal-light` |
| launchd | `~/Library/LaunchAgents/app.signal-light.daemon.plist` |
| 钩子 socket | `~/Library/Application Support/SignalLight/bridge.sock` |

## 开发

```bash
make help                  # build / install / test / package / lint / format / clean
scripts/test.sh            # 跑测试；只装 CommandLineTools 的机器也能跑
scripts/check-cli-copy.sh  # 文案检查：输出不带"了"（不了/为了/除了 除外）
zsh scripts/package-cli.sh # 出包：output/cli-package/signal-light-<版本>-macos-<架构>.zip
zsh scripts/setup-dev-signing.sh  # 可选：固定签名，重编译后不用反复授权蓝牙
```

CI 在每次 push 时跑构建 + 测试 + SwiftFormat/SwiftLint + 文案检查。

## 固件

检查与下载都走网络清单，与源码放在哪无关：

- 清单 `https://raw.githubusercontent.com/itdragons/open-vibe-island/wg/signal-light/<hardware>/firmware/version.json`
- 固件 `https://cdn.jsdelivr.net/gh/itdragons/open-vibe-island@wg/signal-light/<hardware>/firmware/<file>.bin`

固件源码与发布流程在 `open-vibe-island` 仓库的 `wg` 分支。

## 注意

- 附近可能有别人的红绿灯：`pair` 会列出扫到的设备，`--first` 只在唯一候选时才生效。
- `service start` / `run` 使用真实主目录（launchd 与 Agent 钩子都按真实主目录找 socket）。
- 只想让某个子进程不触发钩子：`SIGNAL_LIGHT_SKIP_HOOKS=1`。

## 来历

红绿灯的固件、BLE 协议与 macOS App 在 `open-vibe-island`（`wg` 分支）；本仓库是独立的命令行产品，设计上参考了那边的实现。
