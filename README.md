# M3U 多路监控播放器（M3U Player）

基于 **Flutter + fvp（MDK 内核）** 的 M3U 多路监控播放器，专注于 **HEVC-in-FLV 摄像头流** 的流畅播放，支持 **Android 手机 / Android TV / Windows 桌面** 三端，一套代码、多画面网格布局、全部参数可调。

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows-blue)
![Version](https://img.shields.io/badge/version-4.0.0-green)
![License](https://img.shields.io/badge/license-MIT-orange)

---

## 目录

- [功能特性](#功能特性)
- [界面与操作](#界面与操作)
- [M3U 配置详解](#m3u-配置详解)
- [平台支持](#平台支持)
- [构建指南](#构建指南)
- [配置说明](#配置说明)
- [项目结构](#项目结构)
- [技术栈](#技术栈)
- [版本历史](#版本历史)
- [许可](#许可)

---

## 功能特性

### 播放能力
- **HEVC-in-FLV 硬解**：专为监控摄像头流（H.265 编码 FLV 封装）优化，支持硬解 / 软解 / 自动切换
- **多画面布局**：1 / 2 / 4 / 8 / 16 路同时播放，列布局 / 行布局自由切换
- **快速翻页**：内容不满屏自动翻页；满屏时滑动或滚轮到顶部 / 底部翻页，预加载下一屏
- **低延迟优化**：nobuffer / flush 开关、可调探测大小与分析时长，显著降低首屏延迟

### 操作方式
| 平台 | 操作 |
|------|------|
| 触屏（手机/平板） | 双击进全屏、双指缩放、上下滑动翻页、点右上角关闭全屏 |
| 遥控器（Android TV） | 方向键 + OK 键，网格导航；返回键双击退出应用 |
| 鼠标（Windows） | 双击进全屏、**ESC / 鼠标右键退出全屏**、滚轮到顶/底翻页 |

### 参数可调（控制面板）
- 解码方式（自动 / 硬解 / 软解）
- 探测大小（8K / 32K / 64K / 128K）
- 分析时长（10ms / 20ms / 50ms / 100ms）
- nobuffer / flush 低延迟开关
- 首帧超时 / 心跳超时 / 缓冲秒数 / 重连最大间隔
- 屏幕方向（竖屏 / 横屏 / 自动，Windows 默认横屏）
- 面板样式（底部 / 右侧 / 自动）、分组、码流、频道数等

### 其他
- **配置持久化**：所有设置自动保存，下次启动恢复（Windows 保存在 exe 目录 `config.ini`）
- **画中画**：Android 8.0+ 支持
- **内置操作说明**：各平台专属说明，首启自动弹出
- **关于弹窗**：版本信息、组件架构、作者信息

---

## 界面与操作

### 网格模式（主界面）
- 顶部：标题、当前分组、翻页指示、导入按钮
- 网格：每路监控实时画面，双击放大为单路/全屏
- 底部：控制面板按钮（加载 M3U / 操作说明 / 关于 / 重置参数）
- 右上角：关闭全屏、画中画（Android）

### 全屏模式
- 双击任意画面进入全屏；双击返回网格（触屏）
- Windows：按 **ESC** 或点击**鼠标右键**返回网格
- 全屏时双指/滚轮缩放画面

### 控制面板
| 按钮 | 功能 |
|------|------|
| 加载 M3U 文件 | 导入本地 M3U/M3U8/TXT 频道列表 |
| 操作说明 | 查看本机平台的操作指南 |
| 关于 | 版本号、组件架构构成、作者信息 |
| 重置所有参数 | 恢复默认参数（Windows 保持横屏） |

---

## M3U 配置详解

本播放器使用 M3U 文件描述频道。核心约定：

### 分组
`group-title` 指定频道分组，多个分组用分号 `;` 分隔：

```
#EXTINF:-1 group-title="教室1;清晰",教室1号机
```

- 分号 `;` 后为**码流名**（清晰 / 流畅，可自定义）
- 一个频道只识别第一个 `group-title`
- 没有分组标记的频道归入"全部"

### 码流切换（清晰 / 流畅）
同一摄像头两个地址（清晰 HEVC / 流畅 H.264）：

```
#EXTINF:-1 group-title="教室1;清晰",教室1号机
http://192.168.1.10:8080/live/ch01_0
#EXTINF:-1 group-title="教室1;流畅",教室1号机
http://192.168.1.10:8080/live/ch01_1
```

- URL 结尾 `_0` = 清晰（HEVC），`_1` = 流畅（H.264）
- 控制面板切换"码流"即可在两组之间切换

### 完整示例
```
#EXTM3U
#EXTINF:-1 group-title="教学楼;清晰",101教室
http://10.0.0.11:8080/live/101_0
#EXTINF:-1 group-title="教学楼;流畅",101教室
http://10.0.0.11:8080/live/101_1
#EXTINF:-1 group-title="操场;清晰",操场东
http://10.0.0.12:8080/live/east_0
#EXTINF:-1 group-title="操场;流畅",操场东
http://10.0.0.12:8080/live/east_1
```

---

## 平台支持

| 平台 | 架构 | 产物 | 说明 |
|------|------|------|------|
| Android | arm64-v8a | `app-arm64-v8a-release.apk` | 主流 64 位手机 / 电视盒 |
| Android | armeabi-v7a | `app-armeabi-v7a-release.apk` | 32 位老设备 |
| Android | x86_64 | `app-x86_64-release.apk` | 模拟器 / x86 设备 |
| Windows | x64 | `m3u_player_fvp.exe` | 桌面版，配置存 exe 目录 |

---

## 构建指南

### 环境要求
| 依赖 | 版本 |
|------|------|
| Flutter | 3.47+（Dart 3.13+） |
| Android SDK | minSdk 24 / targetSdk 34，JDK 17+ |
| Visual Studio | 2022（含"使用 C++ 的桌面开发"组件） |

### 构建 Android（分 ABI 输出 3 个 APK）
```bash
flutter build apk --release --split-per-abi
# 输出：build/app/outputs/flutter-apk/
#   app-arm64-v8a-release.apk
#   app-armeabi-v7a-release.apk
#   app-x86_64-release.apk
```

> 注意：`android/app/build.gradle.kts` 中**不要**写 `ndk.abiFilters`，否则与 `--split-per-abi` 的 Gradle splits 机制冲突导致构建失败。

### 构建 Windows
```bash
flutter build windows --release
# 输出：build/windows/x64/runner/Release/m3u_player_fvp.exe
```

### 运行调试
```bash
flutter run -d <device>       # 手机/模拟器
flutter run -d windows        # Windows 桌面
```

---

## 配置说明

所有面板参数保存到配置文件，启动时自动加载。

| 平台 | 配置文件位置 |
|------|-------------|
| Windows | exe 所在目录 `config.ini`（UTF-8 无 BOM） |
| Android | SharedPreferences（应用内部） |

### config.ini 键值说明（Windows）

| 键 | 说明 | 示例 |
|----|------|------|
| layout | 布局（网格 2x2 等） | 2 |
| columns / rows | 自定义行列数 | 0（自动） |
| preload | 预加载页数 | 0 |
| group | 当前分组 | 全部 |
| tv_mode | 电视模式（auto/on/off） | auto |
| quality | 码流（清晰/流畅） | 清晰 |
| panel_style | 面板样式（auto/bottom/right） | auto |
| orientation | 屏幕方向（portrait/landscape/auto） | landscape |
| decoder | 解码方式（auto/hard/soft） | auto |
| probesize | 探测大小（字节） | 32768 |
| analyzeduration | 分析时长（微秒） | 20000 |
| nobuffer / flush_packets | 低延迟开关 | true |
| first_frame_timeout | 首帧超时（秒） | 3 |
| heartbeat_timeout | 心跳超时（秒） | 5 |
| buffer_seconds | 缓冲秒数 | 0 |
| reconnect_delay_max | 重连最大间隔（秒） | 7 |
| guide_shown | 首次操作说明是否已展示 | true |

> 首次运行 Windows 版会自动把旧版本存在 `%APPDATA%\m3u_player_fvp` 或工作目录的 `config.ini` / `my_channels.m3u` 复制到 exe 目录（不删除源文件）。

---

## 项目结构

```
├── lib/
│   ├── main.dart              # 入口：注册 fvp、启动方向策略（Windows 保持横屏）
│   ├── home_page.dart         # 主页面：网格/全屏/控制面板/操作说明/关于
│   ├── m3u_parser.dart        # M3U 解析（分组、码流、URL 提取）
│   ├── native_io.dart         # 原生 IO：文件选择、配置持久化、旧配置迁移
│   └── native_player.dart     # fvp 播放器封装（硬解/软解、参数配置）
├── android/                   # Android 工程（自写 MainActivity，minSdk 24）
├── windows/                   # Windows 工程（Win32 runner）
├── test/
│   └── widget_test.dart       # 冒烟测试
├── pubspec.yaml               # 依赖与版本
├── README.md                  # 本文档
└── LICENSE                    # MIT 许可
```

---

## 技术栈

| 组件 | 说明 |
|------|------|
| Flutter 3.47 / Dart 3.13 | UI 框架 |
| fvp 0.38.1（MDK 内核） | 播放内核：HEVC-in-FLV 硬解 |
| FFmpeg | 解码 / 解复用 |
| 自写 MethodChannel | 文件选择、SharedPreferences（替代三方插件，兼容 Android 6 电视） |

---

## 版本历史

| 版本 | 日期 | 说明 |
|------|------|------|
| **v4.0.0** | 2026-09 | Windows 版完善：ESC/右键退出全屏、滚轮翻页、配置持久化到 exe 目录、配置合并写入修复；控制面板"关于"；分 ABI 构建 |
| v3.9.0 | 2026-09 | 稳定版：所有参数可调、完整操作说明、全屏沉浸式 |

---

## 许可

MIT License — Copyright (c) 2026 **gtyphoon**

详见 [LICENSE](LICENSE)。
