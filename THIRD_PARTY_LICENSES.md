# 第三方开源组件许可声明（Third-Party Notices）

本项目（M3U 多路监控播放器，MIT License）在构建和运行时使用了以下开源组件。
按各组件许可要求，在此列出其版权与许可信息；各组件许可全文见 `LICENSES/` 目录。

## Dart / Flutter 依赖（源码级）

| 组件 | 版本 | 许可 | 版权 |
|------|------|------|------|
| [fvp](https://pub.dev/packages/fvp)（MDK 的 Flutter 播放器封装） | 0.38.1 | BSD-3-Clause | Copyright 2022 Wang Bin. All rights reserved. |
| [file_picker](https://pub.dev/packages/file_picker) | 8.3.7 | MIT License | Copyright (c) 2018 Miguel Ruivo |
| [desktop_drop](https://pub.dev/packages/desktop_drop) | 0.4.4 | Apache-2.0 | Copyright (c) 2021 kinglisky / xiao zhou |
| [path_provider](https://pub.dev/packages/path_provider) | 2.1.6 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| [shared_preferences](https://pub.dev/packages/shared_preferences) | 2.5.5 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| [cupertino_icons](https://pub.dev/packages/cupertino_icons) | 1.0.9 | MIT License | Copyright (c) 2016 The Flutter Authors |

> 说明：以上均为**锁定版本**（见 `pubspec.lock`），以动态链接 / 常规依赖方式使用，许可均为宽松型（MIT / BSD-3 / Apache-2.0），允许自由使用与再分发，只需保留版权声明，本项目已在 `LICENSES/` 中附带各许可原文。

## 播放内核（随 fvp 捆绑的二进制组件）

| 组件 | 版本 | 说明 | 许可 | 版权 |
|------|------|------|------|------|
| [MDK (MediaDevelopmentKit)](https://github.com/wang-bin/mdk-sdk) | 0.38.x | 跨平台多媒体播放内核（`mdk.dll` 等），fvp 的底层引擎 | BSD-3-Clause（随 fvp 包分发） | Copyright 2022 Wang Bin. All rights reserved. |
| [FFmpeg](https://ffmpeg.org/) | 9.x（avbuild master/lite 构建） | 视频解码/解复用（`ffmpeg-9.dll`），由 MDK SDK 动态加载 | **LGPL-2.1+**（详见下文） | Copyright (c) 2000-2024 the FFmpeg developers |

### 关于 FFmpeg 的 LGPL 说明

Windows 版中的 FFmpeg（`ffmpeg-9.dll`）以 **LGPL-2.1 或更新版本**配置编译，
且以**独立动态链接库**形式随程序分发（运行时由 MDK 动态加载），满足 LGPL 的
动态链接合规要求：

- 用户可自行下载/替换该 DLL 为任意兼容版本（我们未做任何技术限制）；
- LGPL 允许在满足上述条件的前提下，以闭源或开源方式再分发本程序；
- 如需获取 FFmpeg 源码：https://ffmpeg.org/download.html

## 开发期依赖（不随发布产物分发）

| 组件 | 许可 |
|------|------|
| Flutter SDK | BSD-3-Clause |
| flutter_lints | BSD-3-Clause |

## 如何遵守

- 随本项目发布（GitHub Release / zip / APK）的二进制产物中，均附带本文件及 `LICENSES/` 许可原文；
- 若你修改、再分发本软件，请保留本文件与各许可原文，并在你的发布材料中一并附带。

---

*本项目采用 MIT License 发布，作者 gtyphoon。上述第三方组件各自保留其版权与许可。*
