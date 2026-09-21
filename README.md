# M3U 多路监控播放器（M3U Player）

基于 **Flutter + fvp (MDK)** 的 M3U 多路监控播放器，支持 HEVC-in-FLV 流播放，覆盖 **Android 手机 / Windows 桌面**。

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows-blue)
![Version](https://img.shields.io/badge/version-4.0.0-green)
![License](https://img.shields.io/badge/license-MIT-orange)

## 功能特性

- **多画面布局**：1/2/4/8/16 路同时播放，列布局 / 行布局可调
- **FLV HEVC 硬解**：支持 HEVC-in-FLV 格式（监控摄像头常用），硬解 / 软解 / 自动切换
- **M3U 解析**：支持 `group-title` 分组、码流切换（清晰 / 流畅）
- **快速翻页**：上下滑动翻页、鼠标滚轮到边界翻页，预加载优化
- **全屏模式**：双击进入全屏、双指缩放，沉浸式播放
- **电视 / 遥控支持**：方向键 + OK 操作（Android TV 自动识别）
- **播放器参数可调**：
  - 解码方式（自动 / 硬解 / 软解）
  - 探测大小（8K / 32K / 64K / 128K）
  - 分析时长（10ms / 20ms / 50ms / 100ms）
  - nobuffer / flush 低延迟开关
  - 首帧超时 / 心跳超时 / 缓冲秒数 / 重连最大间隔
- **配置保存**：所有设置自动保存，下次打开恢复
- **画中画**：Android 8.0+ 支持画中画小窗

## 平台支持

| 平台 | 架构 | 说明 |
|------|------|------|
| Android | arm64-v8a | 主流 64 位手机 / 电视盒 |
| Android | armeabi-v7a | 32 位老设备 |
| Android | x86_64 | 模拟器 |
| Windows | x64 | 桌面版（ESC / 右键退出全屏，滚轮翻页，拖拽加载 M3U） |

## 快速开始

### 环境要求

- Flutter 3.47+（Dart 3.13+）
- Android SDK（构建 Android 版）
- Visual Studio 2022（含 C++ 桌面开发组件，构建 Windows 版）

### 构建 Android（分 ABI 输出 3 个 APK）

```bash
flutter build apk --release --split-per-abi
# 输出：build/app/outputs/flutter-apk/
#   app-arm64-v8a-release.apk
#   app-armeabi-v7a-release.apk
#   app-x86_64-release.apk
```

### 构建 Windows

```bash
flutter build windows --release
# 输出：build/windows/x64/runner/Release/m3u_player_fvp.exe
# 配置保存在 exe 所在目录 config.ini
```

### 运行

```bash
flutter run -d <device>
```

## M3U 配置说明

- 分组 = `group-title` 的值，如 `group-title="教室1;清晰"`
- 分号 `;` 后面的就是码流名（清晰 / 流畅，可自定义）
- URL 结尾 `_0` = 清晰（HEVC）、`_1` = 流畅（H.264）
- 一个频道只识别第一个 `group-title`
- 没有分组标记的频道归入"全部"

## 项目结构

```
lib/
  main.dart            # 入口：注册 fvp、启动方向策略
  home_page.dart       # 主页面：网格 / 全屏 / 控制面板 / 操作说明 / 关于
  m3u_parser.dart      # M3U 解析
  native_io.dart       # 原生 IO：文件选择、配置持久化（Windows: config.ini）
  native_player.dart   # fvp 播放器封装
android/               # Android 工程（自写 MainActivity，minSdk 24）
windows/               # Windows 工程（Win32 runner）
test/                  # 冒烟测试
```

## 关于

- 作者：**gtyphoon**
- 许可证：[MIT](LICENSE)
- 组件架构：Flutter · fvp (MDK) · FFmpeg

## 版本历史

- **v4.0.0（2026-09-21）**：Windows 版完善（ESC/右键退出全屏、滚轮翻页、配置持久化到 exe 目录）、关于弹窗、分 ABI 构建
- v3.9.0（2026-09-20）：稳定版，所有参数可调，完整操作说明，全屏沉浸式
