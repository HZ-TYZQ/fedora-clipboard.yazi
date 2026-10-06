# 回归测试

在仓库根目录运行：

```sh
lua tests/stale.lua
python3 -m unittest discover -s tests -v
```

第一条也可以使用 `luajit tests/stale.lua`。Python 测试仅依赖标准库，需要 Linux。

- `stale.lua` 加载实际插件，模拟 Yazi API 和辅助进程，验证同步失败、读取恢复、重试成功和取消 yank 后的粘贴行为。
- `test_helper.py` 加载实际内嵌 Python，使用真实管道和模拟 Wayland 事件，验证读取所有权标记期间的接管以及条件清空。

测试不访问真实系统剪贴板，也不执行真实文件移动。
