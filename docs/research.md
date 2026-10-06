# Dolphin 与 GNOME Files（Nautilus）的文件剪贴板实现调研

调研对象与源码版本（2026-10-06 拉取）：

| 项目 | 本机安装版本 | 阅读的源码 |
| --- | --- | --- |
| GNOME Files (Nautilus) | 50.3.1 | `GNOME/nautilus` main @ `dc34d53` |
| GTK 4（Nautilus 的剪贴板序列化在 GTK 里） | — | `GNOME/gtk` main：`gdk/gdkcontentserializer.c`、`gdk/gdkcontentdeserializer.c`、`gdk/filetransferportal.c` |
| Dolphin | 26.08.1 | `KDE/dolphin` master @ `4072241` |
| KIO（Dolphin 的复制/粘贴逻辑在 KIO 里） | — | `KDE/kio` master @ `b8ec703` |
| KCoreAddons（`KUrlMimeData`） | — | `KDE/kcoreaddons` master @ `29c228d` |

## 0. 背景：Linux 桌面剪贴板如何传递“文件”

- 剪贴板里放的并不是文件本身，而是一组 **MIME 类型**的报价（offer）。粘贴方挑一个自己认识的类型，
  通过管道向复制方索取数据；数据是**按需、惰性**传输的，所以复制方进程必须一直活着，
  直到别的程序接管剪贴板。
- 文件用 URI 列表表示（`file:///home/user/a%20b.txt`，需要百分号编码）。
- “剪切”在 X11/Wayland 剪贴板里**没有标准表示**。各桌面用私有 MIME 类型携带“这是剪切”这一标记，
  这正是 GNOME 与 KDE 之间互通的难点。

## 1. GNOME Files（Nautilus，GTK 4）

### 复制 / 剪切

`action_copy` / `action_cut`（`src/nautilus-files-view.c:5865`、`:5881`）都调用
`nautilus_clipboard_prepare_for_files()`（`src/nautilus-clipboard.c:287`），它把两个
`GdkContentProvider` 合并后交给 `gdk_clipboard_set_content()`：

1. `NAUTILUS_TYPE_CLIPBOARD`（`{ cut, files }` 结构体），在 `nautilus_clipboard_register()`
   （`:310`）中注册了序列化器，对外表现为 **`x-special/gnome-copied-files`**：

   ```text
   copy                      ← 或 cut
   file:///home/u/a%20b.txt
   file:///home/u/dir
   ```

   第一行是 `copy`/`cut`，后面每行一个 URI，用 `\n` 分隔，**末尾没有换行**。
2. `GDK_TYPE_FILE_LIST`（`GSList<GFile>`），由 GTK 自己序列化成：
   - `text/uri-list`：每个 URI 后跟 `\r\n`（`gdkcontentserializer.c:850`，`file_uri_serializer`）；
   - `text/plain;charset=utf-8`：本地路径，用 `\n` 分隔、末尾无换行（`:899`，`file_text_serializer`）——
     所以在文本编辑器里粘贴得到的是路径；
   - `application/vnd.portal.filetransfer`、`application/vnd.portal.files`
     （`filetransferportal.c`）：通过 xdg-desktop-portal 的 Documents/FileTransfer 接口
     把文件传给 Flatpak 沙箱应用（详见第 5 节）。

### 粘贴

`paste_files()`（`src/nautilus-files-view.c:2751`）按以下优先级读取：

1. 剪贴板含图像（`GDK_TYPE_TEXTURE`）→ 把图片保存为新文件；
2. `x-special/gnome-copied-files` → `cut` 时执行**移动**，否则复制；
3. `text/uri-list`（`GDK_TYPE_FILE_LIST`）→ **总是复制**；
4. 单个 `G_TYPE_FILE` → 复制。

剪切粘贴完成后，`handle_clipboard_data()`（`:2671`）调用
`gdk_clipboard_set_content(clipboard, NULL)` **清空剪贴板**——剪切的内容只能粘贴一次。
另外，在 Nautilus 内拖放/移动的文件若正好在本进程持有的剪贴板里，也会清空剪贴板
（`nautilus_clipboard_clear_if_colliding_uris()`，`nautilus-clipboard.c:100`）。

### 解析很严格

`nautilus_clipboard_from_string()`（`nautilus-clipboard.c:54`）要求：

- 第一行必须**恰好**是 `cut` 或 `copy`；
- **不允许空行**——所以末尾多一个 `\n` 就会整段被拒绝（“Nautilus Clipboard must not have empty lines.”）；
- 每一行都必须通过 `g_uri_is_valid()`，即必须是正确百分号编码的 URI。

> 源码注释：“While it's not a public API and the format is not documented, some apps have come to use this
> atom/mime type to integrate with our clipboard.” —— Nemo、Caja、Thunar、PCManFM 等都沿用了这个格式。

## 2. Dolphin（KDE，Qt 6 / KF6）

### 复制 / 剪切

`DolphinView::copySelectedItemsToClipboard()` / `cutSelectedItemsToClipboard()`
（`src/views/dolphinview.cpp:969`、`:961`）：

```cpp
QMimeData *mimeData = selectionMimeData();       // KFileItemModel::createMimeData
KIO::setClipboardDataCut(mimeData, true);         // 仅剪切时
KUrlMimeData::exportUrlsToPortal(mimeData);
QApplication::clipboard()->setMimeData(mimeData);
```

产生的 MIME 类型：

| 类型 | 内容 | 来源 |
| --- | --- | --- |
| `text/uri-list` | “最本地化”的 URL（`mostLocalUrl`，如 `desktop:/` 会转成 `file://`） | `KUrlMimeData::setUrls()` → `QMimeData::setUrls()` |
| `application/x-kde4-urilist` | KIO 原始 URL（可能是 `smb://`、`sftp://`、`trash:/` 等），`\r\n` 分隔 | `KUrlMimeData::setUrls()`（`kurlmimedata.cpp:49`） |
| `application/x-kde-cutselection` | 剪切时为 `1` | `KIO::setClipboardDataCut()`（`kio/src/widgets/paste.cpp:263`） |
| `application/vnd.portal.filetransfer` | 门户传输 key（Documents 门户可用时） | `KUrlMimeData::exportUrlsToPortal()`（`kurlmimedata.cpp:282`） |
| `text/plain` | Qt 从 URL 列表派生 | Qt |

### 粘贴

`DolphinView::pasteToUrl()`（`:2711`）→ `KIO::paste()` → `PasteJobPrivate::slotStart()`
（`kio/src/widgets/pastejob.cpp:54`）：

1. `move = KIO::isClipboardDataCut(mimeData)`：**只看** `application/x-kde-cutselection` 的第一个字节是否为 `1`
   （`paste.cpp:269`）；
2. 有 URL 时，`KUrlMimeData::urlsFromMimeData(..., PreferLocalUrls)`（`kurlmimedata.cpp:172`）依次尝试：
   门户 `application/vnd.portal.filetransfer`（来源不是自己且门户可用时）→ `text/uri-list` → `application/x-kde4-urilist`；
   然后执行 `KIO::move` 或 `KIO::copy`；
3. 没有 URL 时（纯文本、图片），弹出对话框，把剪贴板内容**另存为新文件**。

### 剪切粘贴之后

Dolphin **不清空**剪贴板。`KIO::move()` 会挂一个 `ClipboardUpdater(UpdateContent)`
（`kio/src/core/copyjob.cpp:2818`），移动完成后把剪贴板里的 URL **改写成新位置**，
写回的是一个不带剪切标记的新 `QMimeData`（`clipboardupdater.cpp:50`）——
于是剪贴板变成了“复制新位置的文件”。删除文件时则从剪贴板里移除对应 URL（`RemoveContent`）。

## 3. 对比与互通问题

| | Nautilus | Dolphin |
| --- | --- | --- |
| 文件列表 | `x-special/gnome-copied-files` + `text/uri-list` | `text/uri-list` + `application/x-kde4-urilist` |
| 剪切标记 | `x-special/gnome-copied-files` 第一行 `cut` | `application/x-kde-cutselection` = `1` |
| 文本粘贴结果 | 本地路径 | 由 Qt 从 URL 派生 |
| 读取时的剪切判断 | 只认 `x-special/gnome-copied-files` | 只认 `application/x-kde-cutselection` |
| 剪切粘贴后 | 清空剪贴板 | 把剪贴板改写为新位置（复制语义） |
| 沙箱应用 | `application/vnd.portal.filetransfer` / `.files` | `application/vnd.portal.filetransfer` |
| 非文件内容粘贴 | 图像 → 新图片文件 | 文本/图像 → 询问文件名后另存 |

**结论：两者的“剪切”互不相通。** 在 Nautilus 里剪切、到 Dolphin 里粘贴，Dolphin 只看到
`text/uri-list` 而没有 `x-kde-cutselection`，于是执行**复制**；反之亦然。
二者唯一的公共格式是 `text/uri-list`，它只能表达“复制”。

## 4. 对本插件设计的影响

1. **写入**（yazi 的 `y`/`x` → 系统剪贴板）：同时提供两家的格式——
   `x-special/gnome-copied-files`（带 `cut`/`copy`，末尾无换行）、`text/uri-list`（`\r\n` 结尾）、
   剪切时再加 `application/x-kde-cutselection: 1`，外加 `text/plain` 路径。
   这样 Nautilus 和 Dolphin 都能正确识别剪切，顺带弥补了两者之间的互通缺口。
2. **读取**（系统剪贴板 → yazi 的 `p`）：先读 `x-special/gnome-copied-files`，
   再退回 `text/uri-list` + `application/x-kde-cutselection`。
3. **剪切只能粘贴一次**：在 yazi 中粘贴外部剪切的文件后清空剪贴板（采用 Nautilus 的做法，
   比 Dolphin 的“改写为新位置”更简单，也与 yazi 剪切粘贴后自动取消 yank 的行为一致）。
4. **需要多 MIME 类型同时提供** → `wl-copy` 一次只能提供一种类型，无法满足。插件内嵌了一个
   只依赖 Python 标准库的 Wayland 客户端，使用 `ext-data-control-v1` /
   `wlr-data-control-unstable-v1` 协议（剪贴板管理器用的协议，不需要窗口焦点），
   后台守护进程负责按需提供数据，被别的程序接管剪贴板时自动退出。
   GNOME Shell（Mutter）不支持 data-control，此时退回 `wl-copy`，只提供 GNOME 的那一种类型。
5. **为什么不直接改写 yazi 的 yank 列表**：yazi 的 `update_yanked` 动作只接受 DDS `@yank`
   事件里的内部对象，而 `Ember::validate()` 禁止插件构造 `@yank` 事件，Lua 侧没有任何 API
   能把任意路径放进 yank 列表。因此“系统 → yazi”方向采用“粘贴时同步”：按 `p` 时读取系统剪贴板，
   若其中的文件与 yazi 的 yank 不同，就以系统剪贴板为准，用 `ya.task("copy"/"move")` 执行粘贴。
6. **沙箱应用**：Flatpak 版 Chrome 的沙箱只能看到 `~/Downloads`、`~/Documents` 等少数目录，
   `text/uri-list` 里的其他路径对它不存在，所以只给 URI 时网页里粘贴不了文件。
   Dolphin 能成功，是因为 `KUrlMimeData::exportUrlsToPortal()` 先调用文档门户的
   `FileTransfer.StartTransfer(autostop=false)` + `AddFiles(fds)`，再把返回的 key 放进
   `application/vnd.portal.filetransfer`；Chrome 读到 key 后调用 `RetrieveFiles`，
   得到沙箱内可访问的 `/run/user/<uid>/doc/...` 路径（宿主程序调用则直接得到原路径）。
   本插件照此实现，并同时提供 GTK 使用的旧名字 `application/vnd.portal.files`。
   GTK 写入的 key 末尾带 NUL，Dolphin 不带；插件采用 Dolphin 的写法。
7. **未覆盖**：非本地 URI（`sftp://`、`smb://` 等，会被跳过并提示）。

## 5. 把文件交给沙箱应用：三种门户实现的对比

Flatpak 应用（例如 Flatpak 版 Chrome）只能看到被授权的少数目录，`text/uri-list` 里的路径通常对它无效。
三方都借助 xdg-desktop-portal 的文档门户 `org.freedesktop.portal.FileTransfer` 解决：
复制方 `StartTransfer` 后用 `AddFiles` 传入文件描述符，把得到的 key 放进剪贴板；
粘贴方用 key 调用 `RetrieveFiles`，沙箱应用拿到 `/run/user/<uid>/doc/<id>/<文件名>`，宿主程序则直接拿到原路径。

Nautilus 自己没有这部分代码（它的 `nautilus-portal.c` 是文件选择器门户的后端，与剪贴板无关），
全部由 GTK 完成：复制时放进剪贴板的 `GDK_TYPE_FILE_LIST`，除了序列化成 `text/uri-list` 外，
还注册了到门户类型的序列化器（`gdk/filetransferportal.c`，本机 GTK 4.22.5 与 main 分支逻辑一致）。

| | Nautilus（GTK 4） | Dolphin（KCoreAddons） | 本插件 |
| --- | --- | --- | --- |
| 何时登记 | **惰性**：有程序请求门户类型时才登记，每次请求都新建一次传输 | 复制时立即登记 | 复制时立即登记（在后台守护进程中） |
| `autostop` | `TRUE`：key 被取用一次即失效，下次粘贴会重新登记 | `false`：剪贴板数据被销毁时调用 `StopTransfer` | `false`：守护进程退出、D-Bus 连接断开时由门户自动结束 |
| `writable` | `TRUE`：沙箱应用可以写回文件 | 未设置（只读） | 未设置（只读） |
| 文件描述符 | `O_PATH`，每 16 个一批（总线对单条消息的 fd 数有限制） | `O_RDONLY \| O_NONBLOCK` | `O_PATH`，每 16 个一批 |
| 写入的 key | 末尾带 NUL | 不带 NUL | 不带 NUL |
| MIME 类型 | `application/vnd.portal.filetransfer`，外加 GTK 4.6 误用的旧名 `application/vnd.portal.files` | 只有 `application/vnd.portal.filetransfer` | 两个都提供 |
| 宿主机上是否启用 | `gdk_display_should_use_portal()`：沙箱内总是启用；宿主机上只要门户服务可激活也启用（可用 `GDK_DEBUG=no-portals` 关闭） | `org.freedesktop.portal.Documents` 可激活时 | 文档门户可用时，失败则静默跳过 |
| 无本地路径的文件 | 丢弃（`g_file_peek_path()` 为空） | 非本地 URL 需要 kio-fuse，否则整体放弃导出 | 只处理本地文件 |

读取方面，GTK 的门户反序列化器会在 key 后补一个 NUL 再使用，所以带不带 NUL 都能读；
GTK 的反序列化器按注册顺序排列，`text/uri-list` 在门户类型之前，因此 GTK 程序读取文件列表时优先使用 `text/uri-list`。
Dolphin 则相反：只要来源不是自己且门户可用，就优先读门户（`KUrlMimeData::urlsFromMimeData()`），取不到再退回 `text/uri-list`。

本插件采用 Dolphin 的“复制时登记”方式：辅助进程本来就常驻后台，D-Bus 连接与剪贴板所有权同生共死，
不需要处理 Nautilus 那种在粘贴请求到来时再异步登记的流程。权限上保持只读，比 Nautilus 的可写更保守，
对浏览器上传文件这类用途已经足够。

## 附：yazi 自带的终端剪贴板支持

yazi 26.8 起支持 kitty 的 OSC 5522 剪贴板协议：在 kitty 里按终端的粘贴快捷键（如 `Ctrl+Shift+V`）时，
yazi 会读取 `text/uri-list` 并把文件**复制**到当前目录（`yazi-plugin/preset/components/root.lua` 的
`Root:clipboard`）。它只在支持 OSC 5522 的终端里可用，不区分剪切，也不会把 yazi 的 yank 写回剪贴板。
本插件与之互不冲突。
