# voxtype-codex-dictation（中文说明）

> English version: [README.md](README.md)

在 Linux 上用 **[Voxtype](https://voxtype.io)** 做全局「按键说话」语音输入，
但把录音交给 **ChatGPT 的转写后端**（就是 Codex 桌面应用用的那个）来识别，
而**不用本地的 Whisper 模型**。

说话 → Voxtype 录音 → 一个超小的本地代理帮你带上 ChatGPT 登录信息 → ChatGPT 转写 →
文字直接打在你的光标处。不用本地 GPU 模型、不用 OpenAI API key、不用额外订阅——
直接复用你已经通过 Codex 登录好的 ChatGPT 账号。

```
┌──────────┐   WAV（按键说话）       ┌─────────────────────┐   HTTPS + ChatGPT token   ┌─────────────────────────┐
│ Voxtype  │ ─────────────────────► │ voxtype-codex-proxy │ ────────────────────────► │ chatgpt.com             │
│ （守护进程）│   127.0.0.1:8377       │ （本地 Go 程序）      │   浏览器 UA + Bearer       │ /backend-api/transcribe │
└──────────┘ ◄───────────────────── └─────────────────────┘ ◄──────────────────────── └─────────────────────────┘
        把文字打出来        {"text": "..."}         从 ~/.codex/auth.json 读取并加上鉴权
```

**这个代理是跨平台共用的**；不同的只是「采集端」（热键 + 录音 + 输出）：

| 平台 | 采集端 | 热键 | 状态 |
|------|--------|------|------|
| **Linux**（Wayland/Hyprland + systemd） | [Voxtype](https://voxtype.io) 守护进程 | SUPER+CTRL+X 切换 · **F9 按住** | ✅ 支持 |
| **macOS**（12+） | 仓库自带的 `voxtype-mac`（Swift 单文件） | **按住 fn** | ✅ 支持 |
| **Windows** | — | — | ❌ 不支持 |

- **Linux** 用户：继续往下看。
- **macOS** 用户：完整步骤见 **[mac/README.md](mac/README.md)**；简版见下面的
  [macOS 快速开始](#macos-快速开始)。

---

## macOS 快速开始

完整说明（含权限授予）在 **[mac/README.md](mac/README.md)**。简版：

```bash
brew install go sox           # sox 负责录音；go 用来编译代理
xcode-select --install        # 提供 swiftc（已装可跳过）

git clone <这个仓库的地址> voxtype-codex-dictation
cd voxtype-codex-dictation
./mac/build.sh                # 把 proxy + voxtype-mac 编译进 ~/.local/bin
./mac/install-agents.sh       # 可选：把两个程序装成登录后台代理
```

首次运行会弹出 **麦克风 / 输入监控 / 辅助功能** 三个权限——全部允许后重启客户端。
之后 **按住 fn** 说话、松开，转写结果就粘贴到光标处。

macOS 客户端做的事和 Linux 流程一一对应：监听**物理 fn 键**（keyCode 63 的
`NSEvent` 全局监听）→ 按住时用 **`sox`** 录 16kHz 单声道 WAV → 松开后 POST 给同一个
代理 → 把结果**粘贴**出来（写剪贴板 + Cmd+V，再还原原剪贴板）。不需要 Xcode 工程、
不打 `.app` 包、不依赖 Hammerspoon/Karabiner——就一个 Swift 文件
（`mac/voxtype-mac.swift`）编成单个二进制。

---

# Linux 安装

下面都是 Linux 的内容（采集端用 Voxtype）。

## 为什么需要这个代理（一句话版）

Voxtype 自带的「remote」模式可以把音频 POST 给任意「OpenAI 兼容」的
`/v1/audio/transcriptions` 接口——但它**不能自定义 HTTP 头**。
而要跟 ChatGPT 后端对话，需要两样 Voxtype 不会帮你带的东西：

1. **你的 ChatGPT 鉴权**——从 `~/.codex/auth.json` 里拿到的 `Authorization: Bearer <token>`。
2. **真正的浏览器 `User-Agent`**——`chatgpt.com` 前面挡着 Cloudflare，
   只要看起来像机器人就返回 **403**（光一个 `Mozilla/5.0` 也不够）。

所以这个仓库提供一个约 10 MB 的静态 Go 程序，监听 `127.0.0.1:8377`，
对内说 Voxtype 期望的 OpenAI multipart 格式，对外把每个请求带上正确的 token + UA
重新发给 ChatGPT。它**每次请求都重新读** `~/.codex/auth.json`，
所以 Codex 在后台刷新 token 后，代理会自动用上新的，无需任何操作。

它还会**轻度地把音量归一化**（很轻/蓝牙麦克风的录音会被提到一个稳定的响度），
这能切实地提升识别准确率。

---

## 准备工作（依赖）

| 需要 | 用来 | 安装 |
|------|------|------|
| **Linux + systemd + Wayland** | Voxtype 面向 Wayland/Hyprland | — |
| **[Voxtype](https://voxtype.io)** | 语音输入守护进程 | Omarchy：`omarchy-voxtype-install`；其它见 voxtype.io |
| **Codex 登录（ChatGPT）** | 提供 `~/.codex/auth.json` | Codex 桌面应用，或 `codex login` |
| **Go** | 编译代理 | `sudo pacman -S go`，或 https://go.dev/dl |
| **ffmpeg**（可选） | 让安装脚本能跑联通测试 | `sudo pacman -S ffmpeg` |
| **jq**（可选） | 校验你的 auth 文件 | `sudo pacman -S jq` |

> 你需要一个能登录 Codex/ChatGPT 的账号（ChatGPT Plus/Pro 登录即可）。
> 这**不需要**付费的 OpenAI API key。

---

## 安装（一条龙）

```bash
git clone https://github.com/sicko7947/voxtype-codex-dictation
cd voxtype-codex-dictation
./setup.sh
```

`setup.sh` 是幂等且保守的——它会：

1. 检查 Voxtype、Go、以及你的 Codex 登录都在，
2. 把代理编译到 `~/.local/bin/voxtype-codex-proxy`，
3. 安装 Voxtype 配置预设（会**备份**你原有的），
4. 安装 `voxtype-codex-proxy` 这个 systemd **用户**服务，外加给 `voxtype.service` 的两个 drop-in，
5. 启用并启动所有服务，
6. 真跑一次转写往返，确认鉴权 + Cloudflare + 后端全部正常。

然后直接开始说话即可（快捷键见下）。

---

## 怎么用（Hyprland 快捷键）

| 按键 | 作用 |
|------|------|
| **SUPER + CTRL + X** | 切换听写——按一下开始，再按一下停止并转写 |
| **F9（按住）** | 按住说话——按住录音，松开转写 |

- **用 [Omarchy](https://omarchy.org) 的话**，这些快捷键默认就有，啥都不用做。
- **否则**自己加：把 `config/hypr/voxtype.conf` 复制到 `~/.config/hypr/`，
  在 `hyprland.conf` 里加一行 `source = ~/.config/hypr/voxtype.conf`，再 `hyprctl reload`。

说一句话、松手，转写出来的文字就会打在你光标所在的任何地方。

---

## 在 ChatGPT 远程 和 本地模型 之间切换

装好后默认是 **remote（走 ChatGPT）**。想切到本地 Whisper 模型（离线、不联网），
用自带的脚本：

```bash
./switch-mode.sh            # 显示当前模式，然后切换（remote ↔ local）
./switch-mode.sh remote     # 强制切到 ChatGPT 远程
./switch-mode.sh local      # 强制切到本地模型
./switch-mode.sh status     # 只看当前是哪个模式
```

脚本只改 `~/.config/voxtype/config.toml` 里 `[whisper]` 下的那行 `mode`
（每次都会先备份），然后帮你重启服务。

- 切到 **local** 后，用的是 `[whisper]` 下 `model` 指定的模型（比如 `large-v3`）。
  如果你之前把本地模型删了，先下载一个：`voxtype setup model`。
  此时 ChatGPT 代理还在跑但闲置，无害。
- 切到 **remote** 后，确保 Codex（ChatGPT）是登录状态，`~/.codex/auth.json` 是新鲜的。

---

## 装了哪些文件（全部）

| 路径 | 是什么 |
|------|--------|
| `~/.local/bin/voxtype-codex-proxy` | Go 代理程序 |
| `~/.config/voxtype/config.toml` | Voxtype 设为 `mode = "remote"` → 指向代理 |
| `~/.config/systemd/user/voxtype-codex-proxy.service` | 运行代理，随会话自启 |
| `~/.config/systemd/user/voxtype.service.d/10-codex-proxy.conf` | 让代理先于 Voxtype 启动 |
| `~/.config/systemd/user/voxtype.service.d/20-no-eager.conf` | 去掉 `--eager-processing`（见下） |

这里面**没有任何密钥**。你的 ChatGPT token 一直留在 `~/.codex/auth.json`，只在运行时被读取。

### 关于 `--eager-processing` 的修复
Voxtype 的 `--eager-processing` 会**在你还在说话时就分块转写**（本地 Whisper 的降延迟技巧）。
但走远程后端时，每一块都变成一次**独立、没有上下文**的 HTTP 请求，
于是分块接缝处的词会被搞乱。`20-no-eager.conf` 这个 drop-in 去掉了这个参数，
让每句话作为**一个**带完整上下文的请求发送。这是本仓库里**单项最大的准确率提升**。

---

## 可调参数

**代理**（`voxtype-codex-proxy.service` 里的环境变量）：

| 变量 | 默认 | 含义 |
|------|------|------|
| `VOXTYPE_PROXY_PORT` | `8377` | 监听端口（同时要改 `remote_endpoint`） |
| `VOXTYPE_PROXY_HOST` | `127.0.0.1` | 监听地址（**保持本地！**） |
| `VOXTYPE_PROXY_NO_NORMALIZE` | 未设 | 设为 `1` 关闭音量归一化 |
| `VOXTYPE_PROXY_DEBUG_DIR` | 未设 | 设成某目录（如 `/tmp`）会把实际发出的音频 dump 下来，方便排查 |

**Voxtype**（`~/.config/voxtype/config.toml`）：其余都是标准设置。要切回本地模型见上面的「切换」一节，或直接 `mode = "local"`。

**麦克风小贴士**：做语音输入，有线/USB 麦克风远胜蓝牙耳机——蓝牙麦会退化成窄带、压缩很重的模式。
如果准确率差，先查输入设备（`pactl list short sources`）。

---

## 排错

```bash
# 代理起来了吗？
systemctl --user status voxtype-codex-proxy.service
curl http://127.0.0.1:8377/            # -> {"status":"ok", ...}

# 实时日志
journalctl --user -u voxtype-codex-proxy.service -f

# 看 Voxtype 到底发了什么音频（再用 ffprobe/耳朵检查）
systemctl --user set-environment VOXTYPE_PROXY_DEBUG_DIR=/tmp   # 或改 unit 文件
```

| 现象 | 可能原因 / 解决 |
|------|----------------|
| 转写返回 **HTTP 403** | ChatGPT token 没了/过期，或被 Cloudflare 挡。确认 Codex 已登录（`codex login`）；打开一次 Codex 应用刷新 token。 |
| **HTTP 502** | 代理连不上 ChatGPT，或读不到 `~/.codex/auth.json`。看日志。 |
| 句子接缝处文字乱 | `--eager-processing` 还开着——确认装了 `20-no-eager.conf`，并 `systemctl --user daemon-reload && systemctl --user restart voxtype.service`。 |
| 声音小/漏词 | 蓝牙麦，或输入增益低。换有线麦；查 `pactl`。 |
| 不打字 | 需要 `wtype`（Wayland）或 `ydotool`，装一个。 |

---

## Token 与续期

代理自己**不存也不刷新**任何东西——它只是每次请求读一下 `~/.codex/auth.json`。
保持 **Codex（桌面或 CLI）装着并登录**，它会在后台刷新 token。
如果你从 Codex 退出登录，听写会开始返回 403/502，直到你重新登录。

---

## 卸载

```bash
./uninstall.sh
```

会移除代理程序、它的服务、以及两个 drop-in，并重启 Voxtype。
它**不动** `~/.codex/auth.json`，也**不会**重新下载本地模型
（你的 `config.toml` 仍然是 `mode = "remote"`——想要本地转写就改成 `"local"`；
原始配置的备份在 `~/.config/voxtype/config.toml.bak-*`）。

---

## ⚠️ 免责声明

这个工具用你**个人的 ChatGPT 会话 token** 加一个浏览器 User-Agent，
把音频发到 ChatGPT 的**内部**转写接口。它是一个供**个人使用**的非官方集成：
OpenAI 一旦改动接口它随时可能失效，且这么用**可能与 OpenAI 的服务条款冲突**。
与 OpenAI、Voxtype 均无关联。**按原样提供、不作任何担保**——你要为如何使用自己的账号负责。
**不要**把代理暴露到 `127.0.0.1` 以外。

## 许可证

MIT——见 [LICENSE](LICENSE)。
