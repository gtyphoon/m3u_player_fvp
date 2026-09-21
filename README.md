# M3U 播放器（手机版 / Windows 版）

基于 Flutter + fvp (MDK) 的 M3U 监控播放器，支持 HEVC-in-FLV 流播放。

## 功能特性

- **多画面布局**：支持 1/2/4/8/16 路同时播放
- **FLV HEVC 硬解**：支持 HEVC-in-FLV 格式（监控摄像头常用）
- **M3U 解析**：支持 group-title 分组、码流切换（清晰/流畅）
- **快速翻页**：上下滑动翻页（Windows 滚轮到边界翻页），预加载优化
- **全屏模式**：双击进入全屏，双指缩放，沉浸式（隐藏状态栏）
- **Windows 支持**：ESC / 鼠标右键退出全屏，滚轮翻页，拖拽 M3U 加载，方向键 + Enter 操作
- **参数可调**：
  - 解码方式（自动/硬解/软解）
  - 探测大小（8K/32K/64K/128K）
  - 分析时长（10ms/20ms/50ms/100ms）
  - nobuffer / flush 低延迟开关
  - 首帧超时 / 心跳超时 / 缓冲秒数 / 重连最大间隔
- **配置保存**：所有设置自动保存，下次打开恢复（Windows 存于 exe 所在目录 config.ini）
- **画中画**：支持画中画模式（Android）
- **屏幕唤醒**：播放时保持屏幕常亮（Android）

## 技术栈

- Flutter 3.47.4
- fvp 0.38.1（MDK 内核）
- Dart
- Android (arm64-v8a)

## 构建

``bash
# 设置 JAVA_HOME
set JAVA_HOME=G:\software\jdk21\jdk-21.0.12.1+1

# 构建 Release APK
flutter build apk --release

# 构建 Windows 版
flutter build windows --release
``

## 版本

- v3.9.0（2026-09-20）：稳定版，所有参数可调，完整操作说明，全屏沉浸式

## 说明

本项目为手机版（arm64-v8a），TV 版为独立项目。