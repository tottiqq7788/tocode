# Tomaid（app）

macOS 菜单栏文件管理器，Swift/AppKit 原生实现。

## 功能

- 首次启动选择根文件夹，之后可在菜单中修改。
- 右键菜单栏图标 → 弹出根文件夹目录树，子文件夹递归展开。
- 悬停文件夹展开下级；点击文件或文件夹复制绝对路径。
- 左键单击图标 → 若剪贴板是真实存在的文件夹路径，设为新根文件夹。
- 显示隐藏文件。

## 构建

```bash
bash scripts/build.sh        # 编译并打包到 build/Tomaid.app
bash scripts/test.sh         # 运行单元测试
```

## 目录

- `Sources/` 应用源码
- `Tests/` 单元测试
- `Resources/Info.plist` 应用元数据
- `scripts/` 构建与测试脚本
