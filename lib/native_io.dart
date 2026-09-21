import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

/// 原生 IO 通道：替代 file_picker / path_provider / shared_preferences 三个插件。
///
/// 这三个插件都会传递依赖 flutter_plugin_android_lifecycle（minSdk 24），
/// 而电视（Android 6.0.1 / API 23）需要 minSdk 23，因此全部改为
/// MainActivity 内的原生实现，一个 MethodChannel 搞定：
///   - getAppDir ：应用内部文件目录（无需权限）
///   - pickM3U   ：系统文件选择器选 M3U 并直接返回文本内容
///   - prefs*    ：SharedPreferences 读写（面板配置持久化）
class NativeIO {
  static const MethodChannel _ch = MethodChannel('m3u_player/io');

  // Windows 配置文件写入串行化：防止并发读改写互相覆盖丢数据
  static Future<void> _winWriteLock = Future.value();

  /// 应用文档目录绝对路径（内部存储，无需任何权限）
  ///
  /// Windows：使用软件 exe 本身所在目录（config.ini / my_channels.m3u 与
  /// 程序放在一起）。首次运行时把旧版本存在"工作目录"或
  /// %APPDATA%\m3u_player_fvp 下的文件一次性迁移过来，避免配置"丢失"。
  static Future<String> getAppDir() async {
    if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      await _migrateLegacyFiles(exeDir);
      return exeDir;
    }
    return (await _ch.invokeMethod<String>('getAppDir')) ?? '/';
  }

  /// 一次性迁移旧版本的文件到 exe 所在目录（仅当新位置不存在时复制）
  static Future<void> _migrateLegacyFiles(String exeDir) async {
    final appData = Platform.environment['APPDATA'];
    final oldDirs = <String>[
      if (appData != null && appData.isNotEmpty) '$appData\\m3u_player_fvp',
      Directory.current.path,
    ];
    for (final name in const ['config.ini', 'my_channels.m3u']) {
      final newFile = File('$exeDir\\$name');
      if (await newFile.exists()) continue;
      for (final oldDir in oldDirs) {
        if (oldDir == exeDir) continue;
        final oldFile = File('$oldDir\\$name');
        if (!await oldFile.exists()) continue;
        try {
          await oldFile.copy(newFile.path);
          break;
        } catch (_) {}
      }
    }
  }

  /// 系统文件选择器选 M3U/M3U8/TXT，返回文件文本内容；取消返回 null
  static Future<String?> pickM3U() async {
    if (Platform.isWindows) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['m3u', 'm3u8', 'txt'],
      );
      if (result == null || result.files.isEmpty) return null;
      final file = File(result.files.single.path!);
      return await file.readAsString();
    }
    return await _ch.invokeMethod<String>('pickM3U');
  }

  static Future<String?> prefsGetString(String key) async {
    if (Platform.isWindows) {
      // 等待未完成的写入，避免读到旧内容
      await _winWriteLock;
      final dir = await getAppDir();
      final file = File('$dir/config.ini');
      if (!await file.exists()) return null;
      final lines = await file.readAsLines();
      for (final line in lines) {
        if (line.startsWith('$key=')) {
          return line.substring(key.length + 1);
        }
      }
      return null;
    }
    return await _ch.invokeMethod<String>('prefsGetString', {'key': key});
  }

  static Future<int?> prefsGetInt(String key) async {
    final value = await prefsGetString(key);
    return value == null ? null : int.tryParse(value);
  }

  static Future<bool?> prefsGetBool(String key) async {
    final value = await prefsGetString(key);
    return value == null ? null : value == 'true';
  }

  /// Windows：合并写入 config.ini（整文件单次写回）。
  /// 读现有配置 → 更新本次键值 → 整体写回，保证单键写入（如 guide_shown）
  /// 不会覆盖掉其他配置项；串行锁保证并发"读-改-写"不互相覆盖。
  static Future<void> prefsSetBatch(Map<String, String> config) async {
    if (Platform.isWindows) {
      final prev = _winWriteLock;
      final completer = Completer<void>();
      _winWriteLock = completer.future;
      await prev;
      try {
        final dir = await getAppDir();
        final file = File('$dir/config.ini');
        final merged = <String, String>{};
        if (await file.exists()) {
          final lines = await file.readAsLines();
          for (final line in lines) {
            final idx = line.indexOf('=');
            if (idx > 0) {
              merged[line.substring(0, idx)] = line.substring(idx + 1);
            }
          }
        }
        merged.addAll(config);
        await file.writeAsString(
            merged.entries.map((e) => '${e.key}=${e.value}').join('\n'));
      } finally {
        completer.complete();
      }
      return;
    }
    // Android 等平台：逐条写入 SharedPreferences
    for (final e in config.entries) {
      await _ch.invokeMethod('prefsSet',
          {'key': e.key, 'value': e.value, 'type': 'string'});
    }
  }

  static Future<void> prefsSetString(String key, String value) async {
    await prefsSetBatch({key: value});
  }

  static Future<void> prefsSetInt(String key, int value) async {
    await prefsSetString(key, value.toString());
  }

  static Future<void> prefsSetBool(String key, bool value) async {
    await prefsSetString(key, value.toString());
  }
}
