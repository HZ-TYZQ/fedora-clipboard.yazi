# fedora-clipboard.yazi

让 [yazi](https://github.com/sxyazi/yazi) 的 yank（复制/剪切）与系统剪贴板双向同步，
和 Dolphin、GNOME Files（Nautilus）以及其他文件管理器互相复制、剪切、粘贴文件。

- 在 yazi 里按 `y` / `x`，到 Dolphin 或 Nautilus 里 `Ctrl+V` 即可粘贴；剪切会被识别为**移动**。
- 在 Dolphin 或 Nautilus 里 `Ctrl+C` / `Ctrl+X`，回到 yazi 按 `p` 即可粘贴；剪切同样执行移动。
- 在浏览器网页里粘贴（如 DeepSeek、ChatGPT 的对话框）会直接上传文件，Flatpak 版 Chrome 等沙箱应用也可以。
- 在文本编辑器或终端里粘贴，得到的是文件路径。

## 依赖

- yazi ≥ 26.8.15
- Python ≥ 3.9（只用标准库，Fedora 默认自带）
- 支持 `ext-data-control-v1` 或 `wlr-data-control-unstable-v1` 协议的 Wayland 合成器，
  例如 niri（已测试）、KDE Plasma、Sway、Hyprland
- 可选：xdg-desktop-portal 的文档门户（Fedora 桌面默认自带），用于把文件交给 Flatpak 沙箱应用
- 在不支持上述协议的合成器上（GNOME Shell）会退回使用 `wl-clipboard`（`sudo dnf install wl-clipboard`），
  功能有所降级，见[已知限制](#已知限制)

## 安装

```sh
ya pkg add HZ-TYZQ/fedora-clipboard
```

或者从本地克隆安装（插件目录必须叫 `fedora-clipboard.yazi`，yazi 要求插件名为 kebab-case）：

```sh
git clone https://github.com/HZ-TYZQ/fedora-clipboard.yazi.git
ln -s "$PWD/fedora-clipboard.yazi" ~/.config/yazi/plugins/fedora-clipboard.yazi
```

## 配置

`~/.config/yazi/init.lua`（必需，负责 yazi → 系统剪贴板方向）：

```lua
require("fedora-clipboard"):setup()
```

`~/.config/yazi/keymap.toml`（负责系统剪贴板 → yazi 方向）：

```toml
[[mgr.prepend_keymap]]
on   = "p"
run  = "plugin fedora-clipboard paste"
desc = "Paste from the system clipboard or yanked files"

[[mgr.prepend_keymap]]
on   = "P"
run  = "plugin fedora-clipboard 'paste --force'"
desc = "Paste from the system clipboard or yanked files (overwrite)"
```

`paste` 支持与 yazi 内置 `paste` 动作相同的 `--force`、`--follow` 参数。

### 选项

```lua
require("fedora-clipboard"):setup {
	python = "python3", -- Python 解释器
}
```

## 同步规则

| 操作 | 结果 |
| --- | --- |
| yazi 中 `y` / `x` | 写入系统剪贴板（复制 / 剪切） |
| yazi 中取消 yank（`Y`、`X`），或剪切后已粘贴 | 若剪贴板仍由本 yazi 持有，则清空 |
| 被 yank 的文件被删除或改名 | 若剪贴板仍由本 yazi 持有，则更新为剩余文件；否则不动，不会抢回剪贴板 |
| yazi 中 `p`，剪贴板里有本地文件且与 yazi 的 yank 不同 | 以系统剪贴板为准粘贴；若是剪切，则移动并清空剪贴板 |
| yazi 中 `p`，其他情况 | 执行 yazi 原生 `paste` |

“以最后一次复制为准”：无论是在 yazi 还是在其他程序里复制，`p` 粘贴的都是最近一次复制的文件。

写入剪贴板的格式：

| MIME 类型 | 内容 | 读取方 |
| --- | --- | --- |
| `x-special/gnome-copied-files` | `copy`/`cut` + 每行一个 URI | Nautilus、Nemo、Caja、Thunar 等 |
| `text/uri-list` | 每行一个 URI，`\r\n` 结尾 | 几乎所有程序 |
| `application/x-kde-cutselection` | 剪切时为 `1` | Dolphin 等 KDE 程序 |
| `text/plain`、`text/plain;charset=utf-8`、`UTF8_STRING` | 每行一个路径 | 文本编辑器、终端 |
| `application/vnd.portal.filetransfer`、`application/vnd.portal.files` | 文档门户的传输 key | Flatpak 沙箱应用（如 Flatpak 版 Chrome） |

Dolphin 与 Nautilus 各自只认自己的剪切标记，互相粘贴时剪切会变成复制；
本插件同时提供两种标记，所以经过 yazi 中转不会丢失剪切语义。
详细调研见 [docs/research.md](docs/research.md)。

## 工作原理

- yazi 的 `@yank` 事件触发后，插件读取 yank 列表，交给内嵌的 Python 辅助程序。
  它通过 Wayland data-control 协议成为剪贴板的持有者，然后脱离 yazi 在后台运行，按需向粘贴方提供数据；
  一旦其他程序接管剪贴板就自动退出。因此退出 yazi 后剪贴板内容依然有效。
- `wl-copy` 每次只能提供一种 MIME 类型，无法同时满足 GNOME 和 KDE，这是自带辅助程序的原因。
- Flatpak 应用在沙箱里看不到 `text/uri-list` 中的大多数路径。辅助程序会像 Dolphin 一样，
  通过 D-Bus 把文件登记到 xdg-desktop-portal 的文档门户（`org.freedesktop.portal.FileTransfer`），
  并在剪贴板中提供传输 key；沙箱应用凭 key 取得 `/run/user/<uid>/doc/...` 下可访问的文件。
  这次传输与守护进程同生共死，剪贴板被接管后即失效。
- yazi 没有开放把任意文件放进 yank 列表的 API，因此“系统 → yazi”方向在按 `p` 时进行：
  读取系统剪贴板，必要时用 yazi 的任务系统执行复制/移动，进度和冲突处理与原生粘贴一致。

## 已知限制

- 只支持本地文件；剪贴板中的 `sftp://`、`smb://` 等 URI 会被跳过并提示。
  yank 中包含 yazi 虚拟文件系统里的文件时，`p` 始终执行原生粘贴。
- GNOME Shell 下退回 `wl-copy`，只能提供一种类型（`x-special/gnome-copied-files`），
  在文本编辑器里粘贴不会得到路径，Flatpak 应用也拿不到文件；取消 yank 时也无法清空剪贴板。
  其他不支持 data-control 的合成器上则只提供 `text/uri-list`，剪切会变成复制。
- 不支持 X11 会话。
- yazi 中 yank 标记只反映 yazi 自己的 yank，不会显示其他程序复制的文件。
- `-`、`_`（创建链接）等其他基于 yank 的动作仍只使用 yazi 自己的 yank。
