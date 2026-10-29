# AirPods 音量记忆（中文界面）

本项目基于 [mo-khan98/Airpods-Volume-Memory](https://github.com/mo-khan98/Airpods-Volume-Memory)，将菜单栏、设备管理、连接记录、设置和音量恢复提示翻译为简体中文。保留原项目的事件监听和音量记忆行为。

## 使用

支持 macOS 13 及以上。连接 AirPods 并调整到舒适音量，应用将记住该设备的最新音量，下次连接时自动恢复。设备数据仅保存在本机。

## 从源码构建

需要 Swift 命令行工具，在仓库目录执行：

```bash
bash scripts/build-app.sh
open dist/AirpodVolumeMacApp.app
```

构建脚本会先运行项目测试。完整功能和技术说明参见 [原始 README](README.md)。
