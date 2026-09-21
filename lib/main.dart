import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  fvp.registerWith();
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
      title: 'M3U播放器',
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
