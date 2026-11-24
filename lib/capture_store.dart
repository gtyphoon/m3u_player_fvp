import 'dart:io';

import 'package:flutter/services.dart';

import 'native_io.dart';

/// 截图 / 录制文件的落盘位置与命名。
///
/// 桌面（Windows / Linux）：写在程序所在目录下，跟随文件夹整体拷贝备份：
///   <程序目录>/screenshots/频道名_20261124_173005.png
///   <程序目录>/recordings/频道名_20261124_173005.ts
///
/// Android：写到公共"下载"目录下的本软件目录（不占应用私有空间、用户可直接
/// 在文件管理器里取）：
///   Download/M3U播放器/screenshots/...
///   Download/M3U播放器/recordings/...
/// Android 侧由 MainActivity 的 saveCaptureFile 实现（MediaStore 或旧版文件 API）。
enum CaptureKind { screenshot, recording }

class CaptureStore {
  static const MethodChannel _ch = MethodChannel('m3u_player/io');

  /// Android 下载目录下的软件子目录名
  static const String androidRoot = 'M3U播放器';

  static String folderOf(CaptureKind kind) =>
      kind == CaptureKind.screenshot ? 'screenshots' : 'recordings';

  static String extOf(CaptureKind kind) =>
      kind == CaptureKind.screenshot ? 'png' : 'ts';

  /// 生成文件名：频道名（清洗非法字符）+ 时间戳 + 分段号 + 扩展名
  static String fileName(String channelName, CaptureKind kind, {int part = 0}) {
    final safe = safeName(channelName);
    final t = stamp(DateTime.now());
    final p = part > 0 ? '_part$part' : '';
    return '${safe}_$t$p.${extOf(kind)}';
  }

  /// 去掉文件名里不能用的字符（Windows / Android 都安全），并限制长度
  static String safeName(String raw) {
    var v = raw.replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '_').trim();
    // 只由点和空格组成的名字在 Windows 上不可用
    if (v.isEmpty || v.replaceAll('.', '').isEmpty) v = 'channel';
    if (v.length > 60) v = v.substring(0, 60);
    return v;
  }

  /// yyyyMMdd_HHmmss
  static String stamp(DateTime d) =>
      '${d.year}${_pad2(d.month)}${_pad2(d.day)}_'
      '${_pad2(d.hour)}${_pad2(d.minute)}${_pad2(d.second)}';

  static String _pad2(int v) => v.toString().padLeft(2, '0');

  /// 桌面端截图目录（自定义目录 / 程序目录）
  static Future<Directory> screenshotDir({String? customDir}) =>
      _desktopDir(CaptureKind.screenshot, customDir);

  static Future<Directory> recordingDir({String? customDir}) =>
      _desktopDir(CaptureKind.recording, customDir);

  static Future<Directory> _desktopDir(CaptureKind kind, String? customDir) async {
    final base = (customDir != null && customDir.trim().isNotEmpty)
        ? customDir.trim()
        : await NativeIO.getAppDir();
    final d = Directory('$base${Platform.pathSeparator}${folderOf(kind)}');
    await d.create(recursive: true);
    return d;
  }

  /// 保存一张截图的 PNG 字节，返回可展示给用户的保存位置。
  static Future<String> saveScreenshot(
    Uint8List png,
    String channelName, {
    String? customDir,
  }) async {
    final name = fileName(channelName, CaptureKind.screenshot);
    if (kIsDesktop) {
      final dir = await screenshotDir(customDir: customDir);
      final f = File('${dir.path}${Platform.pathSeparator}$name');
      await f.writeAsBytes(png, flush: true);
      return f.path;
    }
    final path = await _ch.invokeMethod<String>('saveCaptureFile', {
      'name': name,
      'subdir': folderOf(CaptureKind.screenshot),
      'bytes': png,
      'mime': 'image/png',
    });
    if (path == null || path.isEmpty) {
      throw StateError('saveCaptureFile returned null');
    }
    return path;
  }

  /// 桌面端展示用的默认保存根目录
  static Future<String> defaultRoot() async => await NativeIO.getAppDir();
}
