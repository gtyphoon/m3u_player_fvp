import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'home_page.dart';
import 'l10n.dart';
import 'native_io.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  fvp.registerWith();
  // 读取界面语言设置（config.ini 的 lang 键：system/zh/en）
  try {
    L10n.lang = L10n.langFrom(await NativeIO.prefsGetString('lang'));
  } catch (_) {}
  // Windows 桌面端默认横屏（窗口 1280x720），不强制竖屏；
  // 移动端保持竖屏启动，之后由主页面按保存的配置应用方向。
  if (!Platform.isWindows) {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }
  runApp(const M3UPlayerApp());
}

class M3UPlayerApp extends StatelessWidget {
  const M3UPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: L10n.t('M3U播放器'),
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
      ),
      home: MonitorHomePage(),
    );
  }
}
