# signal-light

红绿灯（ESP32-C3）的命令行驱动：不用开 App，在终端里配对、调灯效、跑后台服务，
让 Claude Code / Codex 的会话状态直接体现在实体灯上。macOS 14 起。

- **两个可执行文件**：`signal-light`（CLI + 守护进程）、`agent-hooks`（Agent 钩子转发）。
- **一个库**：`SignalLightKit`（BLE、灯效模型、会话状态、钩子协议）。
- **没有 UI，也不接管审批**：权限弹窗和提问留在 Agent 自己的终端里，灯只做提示。

## 快速开始

```bash
make install                # 构建并安装到本机（重复运行即更新；make help 看全部入口）
signal-light pair           # 扫描 → 选中你的灯（多盏时务必看清名字）
signal-light service start  # 启动后台服务（launchd）
signal-light hooks install  # 接入 Claude Code / Codex（勾选界面）
signal-light                # 不带参数进交互菜单
```

只装 CommandLineTools 的机器用 `make` 即可（它带上 `--build-system native`；直接 `swift build` 需要自己加）。之后新开终端直接敲 `signal-light`。

升级就是重新跑 `make install`（仓库有远端的话先 `git pull` 拿新代码）：配对、灯效配置、launchd 设置一律保留；后台服务在运行的话自动重启。没有变化时说一句「已是最新」，不会白装一遍。装好后敲 `signal-light upgrade` 也会检查源码库：没有新代码就说「已是最新」，有就问你要不要升级。已经构建过的话，也可以直接 `.build/release/signal-light upgrade`。

## 命令

从仓库装到本机用 `make install`（见快速开始）；下表是本机侧的命令。

| 命令 | 作用 |
| --- | --- |
| `upgrade` / `uninstall` | 检查有没有新代码并升级 / 卸载（可一并移除 Agent 钩子） |
| `sign` | 可选：配置固定签名，重建程序后蓝牙授权继续有效 |
| `pair` / `unpair` | 配对红绿灯 / 忘掉已配对设备（会先停服务） |
| `service start\|stop\|restart\|autostart` | 后台服务与开机自启 |
| `hooks install\|status\|uninstall` | 接入 / 查看 / 移除 Claude Code、Codex 钩子 |
| `config` | 各状态的灯效、全局亮度、总开关 |
| `calibrate` | 接线校准：逐个点亮引脚，记下红/黄/绿接在哪 |
| `firmware check\|update` | 检查新固件 / OTA 升级（升级中按 Ctrl-C 可取消） |
| `rename` | 查看或修改灯的蓝牙广播名称（不带参数只看本机记录） |
| `status` / `logs` / `doctor` / `audit` | 状态、日志、体检、文件清单 |

## 灯的表现

| 灯态 | 默认灯效 | 什么时候出现 |
| --- | --- | --- |
| 😴 空闲 | 绿色呼吸 | 没有会话在跑 |
| 🏃 运行中 | 黄色闪烁 | 会话开始 / 提交新提示 |
| 🙋 等待审批 | 黄红呼吸 | Agent 请求权限 |
| ❓ 等待回答 | 黄绿呼吸 | Agent 提问等你选 |

多个会话同时在跑时：**等待你处理的 > 正在运行的 > 空闲**。灯效都能在 `signal-light` 的 🎨 灯效设置或 `config` 里改。

## Agent hooks

只装驱动灯态所需的最小事件集：

| Agent | 装的事件 |
| --- | --- |
| Claude Code | `SessionStart` `UserPromptSubmit` `PermissionRequest` `Stop` `StopFailure` `SessionEnd` |
| Codex | `SessionStart`（覆盖 startup/resume/clear/compact）`UserPromptSubmit` `PermissionRequest` `Stop` `SessionEnd` `Interrupt` |

- 只动本工具写入的条目，原有 hooks（claude-island、cmux 等）不受影响；重复执行幂等。
- **Codex 需要手动信任一次**：装完后在 Codex 里运行 `/hooks` 确认信任，钩子才会运行。
- 审批和提问照常在 Agent 的终端里回答；hook 与弹窗并行，灯只提示、不拦截。

## 架构

```
Agent 钩子 ──stdin JSON──▶ agent-hooks ──Unix socket──▶ 守护进程
                                                              │  SessionRegistry
                                                              ▼
                                                        灯效（BLE）
```

- `Sources/SignalLightKit` — 产品核心：BLE 会话、灯效与设置、会话状态机、钩子协议（`Bridge/`）、Agent 安装器。
- `Sources/SignalLightCLICore` — 命令与交互菜单；`run` 子命令即守护进程本体；`Sources/SignalLightCLI` 是只含 `@main` 的薄入口。
- `Sources/SignalLightHooks` — 单文件转发程序，做完就退出，不阻塞 Agent。
- 钩子协议与状态映射：[docs/bridge.md](docs/bridge.md)。

## 磁盘布局

| 内容 | 位置 |
| --- | --- |
| 程序与数据 | `~/.signal-light/`（`bin/`、`device.json`、`settings.json`、`state.json`、日志） |
| 命令 | `~/.local/bin/signal-light` |
| launchd | `~/Library/LaunchAgents/app.signal-light.daemon.plist` |
| 钩子 socket | `~/.signal-light/bridge.sock` |

## 开发

构建、测试、格式化和检查都在 `make` 里（`make help` 列全部入口）；只装 CommandLineTools 的机器用 `make` 即可（它带上 `--build-system native`）。模块划分、文案规则与工作约定见 [AGENTS.md](AGENTS.md)。

版本号放在仓库根的 `VERSION` 文件，`signal-light --version` 和升级提示都按它显示；判断"有没有新代码"比对的是源码内容哈希，未提交的改动也算数。

CI 在每次 push 时跑构建、测试、格式/lint 与文案检查（`.github/workflows/ci.yml`）。

> `swift build` 报 `Could not initialize build system … Unknown error parsing property list` 时：从 Command Line Tools 27.0（Swift 6.4）起，SwiftPM 的默认构建引擎在没装完整 Xcode 的机器上会这样失败；加 `--build-system native` 用回备用引擎即可（会打一条 deprecation 警告，忽略）。装好完整 Xcode 后 `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`，`swift test` 也才能直接跑。

## 固件

检查与下载都走网络清单，与源码放在哪无关：

- 清单 `https://raw.githubusercontent.com/itdragons/open-vibe-island/wg/signal-light/<hardware>/firmware/version.json`
- 固件 `https://cdn.jsdelivr.net/gh/itdragons/open-vibe-island@wg/signal-light/<hardware>/firmware/<file>.bin`

固件源码与发布流程在 `open-vibe-island` 仓库的 `wg` 分支。

## 注意

- 附近可能有别人的红绿灯：`pair` 会列出扫到的设备，`--first` 只在唯一候选时才生效。
- `service start` / `run` 使用真实主目录（launchd 与 Agent 钩子都按真实主目录找 socket）。
- 只想让某个子进程不触发钩子：`SIGNAL_LIGHT_SKIP_HOOKS=1`。
- 灯不亮时按顺序看：`signal-light status`（指出断在哪一环）、`doctor`（体检）、`logs`（服务实际做了什么）。
- `--color` / `--verbose` / `--quiet` 这类全局参数写在子命令之后，例如 `signal-light status --color=never`。
- 卸载只删本工具写下的东西：`~/.local/bin/signal-light` 只有仍是指向已安装二进制的链接才会被删；别的东西原样保留。
- 给别人用：让对方克隆本仓库后运行 `make install`。

## 来历

本仓库是完全独立的命令行产品，不和 Open Island 共用任何文件与进程，也不会动对方的东西；部分功能的设计参考借鉴了 Open Island。
