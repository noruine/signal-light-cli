# 信号灯 CLI（openisland）

`openisland` 是一个**不需要 macOS App** 的红绿灯工具：把后台服务装到本机，配对红绿灯，然后用 Claude Code / Codex 的会话状态驱动灯效。

只想用红绿灯、不想开 App 的场景，用它就够了。

## 构建

```bash
# 有完整 Xcode 的机器：
swift build -c release --product OpenIslandCli
swift build -c release --product OpenIslandHooks

# 只装了 CommandLineTools（报了 Could not initialize build system 就用这条）：
swift build --build-system native -c release --product OpenIslandCli && swift build --build-system native -c release --product OpenIslandHooks
```

产物在 `.build/release/`。`OpenIslandHooks` 是 hook 转发程序，`install` 时会跟 `openisland` 一起装好，两个都要构建。

> `swift build` 报 `Could not initialize build system … Unknown error parsing property list` 时：从 Command Line Tools 27.0（Swift 6.4）起 SwiftPM 的默认构建引擎换成了 `swiftbuild`，它在没有完整 Xcode 的机器上会这样失败；加 `--build-system native` 用回备用引擎即可（会打一条 deprecation 警告，忽略）。
> 装好完整 Xcode 后 `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`，第一条命令就能直接用，`swift test` 也才能跑。

## 打包

`zsh scripts/package-cli.sh` 把 `openisland`、`OpenIslandHooks` 和一份安装说明打成
`output/cli-package/openisland-cli-<版本>-macos-<架构>.zip`，并打印 sha256。脚本固定用
`--build-system native`，只装 CommandLineTools 的机器也能出包。

## 第一次使用

直接运行不带参数的命令，进入交互菜单，跟着选就行：

```bash
.build/release/OpenIslandCli
```

菜单会按「装到本机 → 配对红绿灯 → 启动服务 → 接入 Agent」逐步引导；顶部始终显示当前状态，以及下一步该做什么。

等价的分步命令：

```bash
.build/release/OpenIslandCli install        # 装到本机（复制程序、建好命令、准备 hooks 组件）
.build/release/OpenIslandCli pair           # 扫描并配对（灯要通电；首次会弹窗要蓝牙权限，点「允许」）
.build/release/OpenIslandCli service start  # 启动后台服务（首次会自动登记 launchd）
.build/release/OpenIslandCli hooks install  # 不带参数进勾选界面，勾 Claude Code / Codex
```

装好后，如果 `~/.local/bin` 已在 PATH 里，就可以直接敲 `openisland`；否则 `install` 会提示怎么把它加进 PATH（fish 是 `fish_add_path ~/.local/bin`）。

## 日常使用

无参数就是菜单，常用操作都在里面：

```bash
openisland          # 🚦 交互菜单：启停、灯效、接入 Agent、设备、诊断、卸载
openisland status   # 服务 / 设备 / 蓝牙 / 当前灯态
```

| 场景 | 命令 |
|---|---|
| 改某个状态的亮法 | `openisland` → 🎨 灯效设置（改完可以直接在实体灯上试） |
| 启停服务 | `openisland service start` / `stop` / `restart` |
| 开机自启 | `openisland service autostart enable` / `disable` / `status` |
| 接入 / 查看 / 移除 Agent | `openisland hooks install` / `status` / `uninstall` |
| 灯的颜色不对 | `openisland calibrate`（逐个点亮引脚，按 r/y/g/n 报色） |
| 检查 / 升级固件 | `openisland firmware check` / `openisland firmware update` |
| 改蓝牙名称 | `openisland rename 新名字` |
| 看服务日志 | `openisland logs`（`--follow` 持续输出） |

### 灯的默认效果

| 灯态 | 默认灯效 | 什么时候出现 |
|---|---|---|
| 😴 空闲 | 绿色呼吸 | 没有会话在跑 |
| 🏃 运行中 | 黄色闪烁 | 会话开始 / 提交了新提示 |
| 🙋 等待审批 | 黄红呼吸 | Agent 请求权限 |
| ❓ 等待回答 | 黄绿呼吸 | Agent 提问等你选 |

多个会话同时在跑时：**等待你处理的 > 正在运行的 > 空闲**。

### Agent hooks 装了什么

只装驱动灯态所需的**最小事件集**，不装逐工具、子代理、通知这类噪音事件：

| Agent | 装的事件 |
|---|---|
| Claude Code | `SessionStart` `UserPromptSubmit` `PermissionRequest` `Stop` `StopFailure` `SessionEnd` |
| Codex | `SessionStart`（覆盖 startup/resume/clear/compact）`UserPromptSubmit` `PermissionRequest` `Stop` `SessionEnd` `Interrupt` |

- 装 hooks **只动本工具写入的条目**，你原有的 hooks（比如 claude-island、cmux）不会被删。
- **Codex 需要一步手动确认**：装完后去 Codex 里敲 `/hooks` 点一次"信任"，hooks 才会运行。
- 重复执行 `hooks install` 是幂等的，不会重复写配置。

### 审批和提问：灯只提示，不接管

openisland 没有审批界面，也不替你做决定：Claude Code / Codex 的权限弹窗照常在它们的终端里出现，你在终端里回答。

- hook 与弹窗**并行**执行（Claude Code 不会等 hook 才显示弹窗），所以装了 hooks 也不会把弹窗挡掉或让你的 Agent 卡住。
- 弹窗等待期间，灯显示「等待审批」（提问则是「等待回答」）；你在终端回答后，灯随会话状态继续更新，最迟在该轮结束时回到「运行中」。
- 想让审批也能在灯这边点——那是 macOS App 的能力，CLI 不带。

## 灯不亮时的排查顺序

```bash
openisland status   # 服务 / 设备 / 蓝牙哪一环断了，下一步该敲什么，它都会说
openisland doctor   # 体检：配对、服务、蓝牙权限、签名稳定性
openisland logs     # 服务实际做了什么
```

## 卸载

菜单里选 🧹，或：

```bash
openisland uninstall
```

卸载会删除本工具的全部文件（程序、配置、日志、launchd 服务），并单独询问是否同时移除 Claude Code / Codex 里的 hooks；脚本里用 `--remove-hooks` 指定。

## 注意

- 从 `.build/` 直接运行的二进制是临时签名，重新构建后 macOS 的蓝牙权限可能要求重新授权。想一劳永逸，按 `install` 输出里的提示做一次固定签名（`codesign --sign "Open Island Dev Local" …`）。
- 命令执行中按 Ctrl-C 会退出整个菜单，而不是只取消当前动作（`firmware update` 的下载和传输阶段除外，那时 Ctrl-C 是取消升级）。
- `service start` / `run` 要在真实主目录下跑（launchd 和 Agent hooks 都用真实主目录）；别带着改过的 `$HOME` 跑它们。
- 卸载只删本工具写下的东西：`~/.local/bin/openisland` 只有在仍是指向已安装二进制的符号链接时才会被删；那里若是别的文件或目录，会原样保留并在输出里说明。
- `--color` / `--verbose` / `--quiet` 这类全局参数写在子命令之后，例如 `openisland status --color=never`。
- 开发提示：`swift test` 需要完整 Xcode（缺 SwiftUI 宏插件时 App 测试目标无法构建）；只装 CommandLineTools 的机器可以只挂载 `OpenIslandCore` 跑 Core 测试。

Hook 事件、载荷字段和响应协议的细节见 [hooks.md](./hooks.md)。
