Togent 的 `pi` 可执行文件由 `scripts/build_togent_runtime.sh` 从
`Vendor/pi-agent` 的固定源码快照构建，并在 `scripts/build.sh` 中复制到 App
资源目录后随 Tocode 一起签名。运行时不从网络下载或自更新 Pi。
