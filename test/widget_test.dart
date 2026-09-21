// 基础冒烟测试：验证工程入口模块可正常编译加载。
// 真实播放功能依赖 fvp 原生插件与运行环境，不在单元测试中全量实例化。

import 'package:flutter_test/flutter_test.dart';

import 'package:m3u_player_fvp/main.dart';

void main() {
  test('入口模块加载正常（M3UPlayerApp 存在）', () {
    expect(M3UPlayerApp, isA<Type>());
  });
}
