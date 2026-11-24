import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'native_player.dart';
import 'native_io.dart';
import 'capture_store.dart';

import 'm3u_parser.dart';
import 'l10n.dart';

/// 布局档位：格子数
const List<int> kLayouts = [1, 2, 4, 5, 6, 7, 8, 16];

// ---------- 应用信息（关于弹窗展示，需与 pubspec.yaml 保持一致） ----------
const String kAppName = 'M3U播放器';
const String kAppVersion = '4.0.3';
const String kAppBuild = '15';
const String kAppAuthor = 'gtyphoon';
const String kAppLicense = 'MIT License';

/// 截图失败提示文案（错误码 → 可操作说明），网格与全屏页共用
String captureErrorText(String? code) => switch (code) {
      'PERMISSION_DENIED' => L10n.t(
          '需要存储权限才能保存截图，请在系统设置里允许本软件使用存储',
          'Storage permission is required to save screenshots. Allow it in system settings.'),
      'no_frame' => L10n.t('截图失败，可能暂无画面'),
      _ => L10n.t('截图失败，请检查保存目录'),
    };

/// 面板形态：auto=自动适配（竖屏底部/宽屏左侧），left=强制左侧抽屉，bottom=强制底部
enum PanelStyle { auto, left, bottom }

/// 主页面：全屏网格 + 自动隐藏信息条 + 唤出式控制面板
///
/// 播放器架构：页面级共享播放器池（_pool），同一 URL 的网格格子与全屏页
/// 共用同一个 NativePlayerController——点进全屏不重新加载、返回不重连。
class MonitorHomePage extends StatefulWidget {
  const MonitorHomePage({super.key});

  @override
  State<MonitorHomePage> createState() => _MonitorHomePageState();
}

class _MonitorHomePageState extends State<MonitorHomePage> {
  // ---------- 列表与筛选状态 ----------
  List<Channel> _allChannels = [];
  List<String> _groups = ['全部'];
  String _group = '全部';
  // TV 模式：null=自动(按系统 LEANBACK 检测)，'on'/'off'=手动覆盖
  String? _tvOverride;
  bool _tvAuto = false;
  bool get _tvEffective =>
      _tvOverride == 'on' || (_tvOverride == null && _tvAuto);
  static const MethodChannel _tvChannel = MethodChannel('m3u_player/tv');
  static const MethodChannel _permChannel = MethodChannel('m3u_player/permission');
  String _quality = '清晰';
  int _layout = 2;
  int _columns = 0; // 列布局：0=自动，1~4=固定列数
  int _rows = 0; // 行布局：0=自动，1~4=固定行数
  int _preload = 0; // 预加载下一页路数：0=不启用
  int _page = 1;

  // ---------- 播放器参数（控制面板可调） ----------
  String _videoDecoder = 'auto';
  int _probesize = 32768;
  int _analyzeduration = 20000;
  bool _nobuffer = true;
  bool _flushPackets = true;
  int _firstFrameTimeout = 3; // 首帧超时（秒）
  int _heartbeatTimeout = 5; // 心跳超时（秒）
  int _bufferSeconds = 0; // 缓冲秒数
  int _reconnectDelayMax = 7; // 重连最大间隔（秒）
  List<Channel> _lastStableChannels = []; // 快速翻页期间保持的最后稳定页内容
  bool _loaded = false;
  bool _checking = true;
  bool _prefsRestored = false; // 启动时是否正在检查持久化列表

  // ---------- 信息条与面板 ----------
  bool _infoVisible = true;
  Timer? _hideTimer;
  bool _panelOpen = false;
  PanelStyle _panelStyle = PanelStyle.auto;

  // 方向锁定：null=自动，landscape=强制横屏，portrait=强制竖屏
  String? _orientationLock = kIsDesktop ? 'landscape' : 'portrait';

  // 截图保存目录（桌面端可自定义；空=程序所在目录）
  String? _captureDir;

  // ---------- 录制 ----------
  final Map<String, _Recording> _recordings = {}; // key = 频道 URL
  String _recFormat = 'auto'; // auto / ts / mkv / mp4
  int _recSegmentMin = 30; // 分段时长（分钟），0=不分段

  // 全屏播放的频道
  Channel? _fullscreenChannel;

  // ---------- 共享播放器池 ----------
  final Map<String, NativePlayerController> _pool = {};
  final Map<String, String> _statuses = {};
  final Map<String, Timer> _retryTimers = {};
  final Set<String> _retryPending = {};
  final ScrollController _gridScroll = ScrollController();
  DateTime? _lastBackTs; // 返回键双击退出计时
  double? _dragStartY; // 翻页手势：按下时的纵坐标
  int _gridFocusIndex = 0; // 遥控：网格选中格索引
  final GlobalKey<_PanelBodyState> _panelKey = GlobalKey();
  static bool _hkBound = false; // 硬件按键只注册一次，防止重复触发

  // 画中画：与 Android 原生 MainActivity 通信（Android 8.0+ 支持）
  static const MethodChannel _pipChannel = MethodChannel('m3u_player/pip');

  @override
  void initState() {
    super.initState();
    // 遥控器按键在硬件层统一捕获（不依赖焦点，避免焦点丢失导致按键失效）
    if (!_hkBound) {
      _hkBound = true;
      HardwareKeyboard.instance.addHandler(_hardKey);
    }
    _detectTv();
    _loadPrefs();
    _poke();
    _loadSavedM3U();
  }

  @override
  void dispose() {
    if (_hkBound) {
      _hkBound = false;
      HardwareKeyboard.instance.removeHandler(_hardKey);
    }
    _hideTimer?.cancel();
    _gridScroll.dispose();
    for (final t in _retryTimers.values) {
      t.cancel();
    }
    for (final c in _pool.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ---------- 状态更新统一入口：先同步播放器池再 setState ----------

  void _update(VoidCallback fn) {
    fn();
    _reconcile();
    if (mounted) setState(() {});
  }

  // ---------- 列表加载 ----------

  /// 启动时优先加载上次手动选择的 M3U（持久化在应用文档目录），
  /// 没有则显示"请选择 M3U"引导页。成品不内置任何 M3U。
  Future<void> _loadSavedM3U() async {
    String? content;
    try {
      final dir = await NativeIO.getAppDir();
      final f = File('$dir/my_channels.m3u');
      if (await f.exists()) content = await f.readAsString();
    } catch (_) {}
    if (content != null) {
      _applyM3U(content, L10n.t('上次选择'));
    } else if (mounted) {
      setState(() => _checking = false);
    }
    await _restorePrefs(); // 必须在列表应用之后（分组要校验存在性）
    await _maybeShowGuide();
  }

  /// 首次打开（电视端）显示操作指引，看过一次后不再弹出
  Future<void> _maybeShowGuide() async {
    try {
      if (await NativeIO.prefsGetBool('guide_shown') ?? false) return;
      await NativeIO.prefsSetBool('guide_shown', true);
      if (!mounted) return;
      await showHelpDialog(context, dismissible: false);
    } catch (_) {}
  }

  /// 恢复上次保存的面板配置（布局/列行/预加载/分组/码流/面板样式/方向）
  Future<void> _restorePrefs() async {
    try {
      final langKey = await NativeIO.prefsGetString('lang') ?? 'system';
      L10n.lang = L10n.langFrom(langKey);
      final layout = await NativeIO.prefsGetInt('layout') ?? 2;
      final columns = await NativeIO.prefsGetInt('columns') ?? 0;
      final rows = await NativeIO.prefsGetInt('rows') ?? 0;
      final preload = await NativeIO.prefsGetInt('preload') ?? 0;
      final quality = await NativeIO.prefsGetString('quality') ?? '清晰';
      final group = await NativeIO.prefsGetString('group') ?? '全部';
      final tvMode = await NativeIO.prefsGetString('tv_mode') ?? 'auto';
      final styleName = await NativeIO.prefsGetString('panel_style') ?? '';
      final orient = await NativeIO.prefsGetString('orientation') ??
          (kIsDesktop ? 'landscape' : 'portrait');
      final decoder = await NativeIO.prefsGetString('decoder') ?? 'auto';
      final probesize = await NativeIO.prefsGetInt('probesize') ?? 32768;
      final analyzeduration = await NativeIO.prefsGetInt('analyzeduration') ?? 20000;
      final nobuffer = await NativeIO.prefsGetBool('nobuffer') ?? true;
      final flushPackets = await NativeIO.prefsGetBool('flush_packets') ?? true;
      final firstFrameTimeout = await NativeIO.prefsGetInt('first_frame_timeout') ?? 3;
      final heartbeatTimeout = await NativeIO.prefsGetInt('heartbeat_timeout') ?? 5;
      final bufferSeconds = await NativeIO.prefsGetInt('buffer_seconds') ?? 0;
      final reconnectDelayMax = await NativeIO.prefsGetInt('reconnect_delay_max') ?? 7;
      if (!mounted) return;
      setState(() {
        _layout = kLayouts.contains(layout) ? layout : 2;
        _columns = columns.clamp(0, 4);
        _rows = rows.clamp(0, 4);
        _preload = preload.clamp(0, 8);
        _videoDecoder = decoder;
        _probesize = probesize;
        _analyzeduration = analyzeduration;
        _nobuffer = nobuffer;
        _flushPackets = flushPackets;
        _firstFrameTimeout = firstFrameTimeout;
        _heartbeatTimeout = heartbeatTimeout;
        _bufferSeconds = bufferSeconds;
        _reconnectDelayMax = reconnectDelayMax;
        _quality = (quality == '清晰' || quality == '流畅') ? quality : '清晰';
        _group = _groups.contains(group) ? group : '全部';
        _tvOverride = tvMode == 'on' || tvMode == 'off' ? tvMode : null;
        _panelStyle = PanelStyle.values.asNameMap()[styleName] ?? PanelStyle.auto;
        _orientationLock = orient == 'auto' ? null : orient;
        _page = 1;
        _prefsRestored = true;
      });
      _poke();
      await _applyOrientationLock();
    } catch (_) {}
  }

  /// 保存当前面板配置（下次启动恢复）
  Future<void> _loadPrefs() async {
    _layout = await NativeIO.prefsGetInt('layout') ?? 2;
    _columns = await NativeIO.prefsGetInt('columns') ?? 0;
    _rows = await NativeIO.prefsGetInt('rows') ?? 0;
    _preload = await NativeIO.prefsGetInt('preload') ?? 0;
    _group = await NativeIO.prefsGetString('group') ?? '全部';
    _tvOverride = await NativeIO.prefsGetString('tv_mode') ?? 'auto';
    _quality = await NativeIO.prefsGetString('quality') ?? '清晰';
    final panelStyleName = await NativeIO.prefsGetString('panel_style') ?? 'auto';
    _panelStyle = PanelStyle.values.firstWhere(
      (e) => e.name == panelStyleName,
      orElse: () => PanelStyle.auto,
    );
    _orientationLock = await NativeIO.prefsGetString('orientation');
    _videoDecoder = await NativeIO.prefsGetString('decoder') ?? 'auto';
    _probesize = await NativeIO.prefsGetInt('probesize') ?? 32768;
    _analyzeduration = await NativeIO.prefsGetInt('analyzeduration') ?? 20000;
    _nobuffer = await NativeIO.prefsGetBool('nobuffer') ?? true;
    _flushPackets = await NativeIO.prefsGetBool('flush_packets') ?? true;
    _firstFrameTimeout = await NativeIO.prefsGetInt('first_frame_timeout') ?? 3;
    _heartbeatTimeout = await NativeIO.prefsGetInt('heartbeat_timeout') ?? 5;
    _bufferSeconds = await NativeIO.prefsGetInt('buffer_seconds') ?? 0;
    _reconnectDelayMax = await NativeIO.prefsGetInt('reconnect_delay_max') ?? 7;
    final captureDir = await NativeIO.prefsGetString('capture_dir');
    _captureDir = (captureDir == null || captureDir.trim().isEmpty)
        ? null
        : captureDir.trim();
    final recFormat = await NativeIO.prefsGetString('rec_format');
    final recMigrated = await NativeIO.prefsGetString('rec_format_auto');
    if (recMigrated == null || recMigrated.isEmpty) {
      // 首次运行新版：默认改为"自动"，把旧版的默认值一次性迁移过来
      _recFormat = 'auto';
      NativeIO.prefsSetBatch({'rec_format': 'auto', 'rec_format_auto': '1'});
    } else {
      _recFormat = (recFormat == null || recFormat.isEmpty) ? 'auto' : recFormat;
    }
    _recSegmentMin = await NativeIO.prefsGetInt('rec_segment_min') ?? 30;
    if (mounted) setState(() {});
  }

  void _savePrefs() {
    // 一次性批量写入整个配置：单文件单次写，避免并发写互相覆盖丢数据
    NativeIO.prefsSetBatch({
      'layout': '$_layout',
      'columns': '$_columns',
      'rows': '$_rows',
      'preload': '$_preload',
      'group': _group,
      'tv_mode': _tvOverride ?? 'auto',
      'quality': _quality,
      'panel_style': _panelStyle.name,
      'orientation': _orientationLock ?? 'auto',
      'decoder': _videoDecoder,
      'probesize': '$_probesize',
      'analyzeduration': '$_analyzeduration',
      'nobuffer': '$_nobuffer',
      'flush_packets': '$_flushPackets',
      'first_frame_timeout': '$_firstFrameTimeout',
      'heartbeat_timeout': '$_heartbeatTimeout',
      'buffer_seconds': '$_bufferSeconds',
      'reconnect_delay_max': '$_reconnectDelayMax',
      'capture_dir': _captureDir ?? '',
      'rec_format': _recFormat,
      'rec_format_auto': '1',
      'rec_segment_min': '$_recSegmentMin',
    });
  }

  Future<void> _importM3UFromFile(String path) async {
    try {
      final file = File(path);
      final content = await file.readAsString();
      if (content.trim().isEmpty) {
        _showTip(L10n.t('文件内容为空'));
        return;
      }
      final channels = parseM3U(content);
      if (channels.isEmpty) {
        _showTip(L10n.t('未识别到有效频道，请检查 M3U 格式'));
        return;
      }
      // 持久化到应用文档目录，下次启动自动加载
      try {
        final dir = await NativeIO.getAppDir();
        final f = File('$dir/my_channels.m3u');
        await f.writeAsString(content, flush: true);
      } catch (e) {
        _showTip(L10n.t('列表已加载，但保存失败: $e', 'List loaded, but save failed: {e}', {'e': e}));
      }
      _applyM3U(content, file.path);
    } catch (e) {
      _showTip(L10n.t('加载 M3U 文件失败: $e', 'Failed to load M3U file: {e}', {'e': e}));
    }
  }

  bool _importingM3U = false; // 防重入：空态连按方向键/OK 只弹一次选择器

  Future<void> _importM3U() async {
    if (_importingM3U) return;
    _importingM3U = true;
    try {
    // 手机/平板：用系统文件选择器（选完自动关闭，无权限问题）
    if (!_tvEffective) {
      String? content;
      try {
        content = await NativeIO.pickM3U();
        if (content == null) return; // 用户取消
      } catch (e) {
        _showTip(L10n.t('无法打开文件选择器: $e', 'Cannot open file picker: {e}', {'e': e}));
        return;
      }
      try {
        if (content.trim().isEmpty) {
          _showTip(L10n.t('文件内容为空'));
          return;
        }
        final channels = parseM3U(content);
        if (channels.isEmpty) {
          _showTip(L10n.t('未识别到有效频道，请检查 M3U 格式'));
          return;
        }
        // 持久化到应用文档目录，下次启动自动加载
        try {
          final dir = await NativeIO.getAppDir();
          final f = File('$dir/my_channels.m3u');
          await f.writeAsString(content, flush: true);
        } catch (e) {
          _showTip(L10n.t('列表已加载，但保存失败: $e', 'List loaded, but save failed: {e}', {'e': e}));
        }
        _applyM3U(content, 'M3U');
      } catch (e) {
        _showTip(L10n.t('读取文件失败: $e', 'Failed to read file: {e}', {'e': e}));
      }
      return;
    }

    // 电视无系统文件选择器：应用内扫描 /sdcard 常见目录并列表选择
    // 存储权限走原生通道请求（Android 6 需运行时授权；自写内核不引第三方权限插件）
    bool granted = true;
    try {
      granted = await _permChannel.invokeMethod<bool>('requestStorage') ?? false;
    } catch (_) {}
    if (!granted) {
      _showTip(L10n.t('需要存储权限才能读取 M3U 文件'));
      return;
    }
    final files = await _scanM3uFiles();
    if (files.isEmpty) {
      _showTip(L10n.t('未找到 M3U 文件，请放到 /sdcard/Download 或 /sdcard 根目录'));
      return;
    }
    final picked = await _pickFileDialog(files);
    if (picked == null) return;
    try {
      final content = await File(picked).readAsString();
      if (content.trim().isEmpty) {
        _showTip(L10n.t('文件内容为空'));
        return;
      }
      final channels = parseM3U(content);
      if (channels.isEmpty) {
        _showTip(L10n.t('未识别到有效频道，请检查 M3U 格式'));
        return;
      }
      // 持久化到应用文档目录，下次启动自动加载
      try {
        final dir = await NativeIO.getAppDir();
        final f = File('$dir/my_channels.m3u');
        await f.writeAsString(content, flush: true);
        await NativeIO.prefsSetBool('m3u_saved', true);
      } catch (e) {
        _showTip(L10n.t('列表已加载，但保存失败: $e', 'List loaded, but save failed: {e}', {'e': e}));
      }
      _applyM3U(content, picked.split('/').last);
    } catch (e) {
      _showTip(L10n.t('读取文件失败: $e', 'Failed to read file: {e}', {'e': e}));
    }
    } finally {
      _importingM3U = false;
    }
  }

  /// 扫描 /sdcard 常见位置的 M3U 文件（最多 2 层目录）
  Future<List<String>> _scanM3uFiles() async {
    final out = <String>{};
    final roots = <String>[
      '/sdcard',
      '/storage/emulated/0',
      '/sdcard/Download',
      '/storage/emulated/0/Download',
      '/sdcard/M3U',
      '/sdcard/m3u',
      '/sdcard/playlist',
    ];
    const skip = {'Android', 'data', 'obb', 'cache', 'app', 'MiUI', 'MIUI'};
    Future<void> walk(Directory dir, int depth) async {
      if (depth > 2) return;
      try {
        await for (final e in dir.list(followLinks: false)) {
          if (e is File &&
              RegExp(r'\.(m3u8?|txt)$', caseSensitive: false)
                  .hasMatch(e.path)) {
            out.add(e.path);
          } else if (e is Directory &&
              depth < 2 &&
              !skip.contains(e.uri.pathSegments.last)) {
            await walk(e, depth + 1);
          }
        }
      } catch (_) {}
    }

    for (final root in roots) {
      final d = Directory(root);
      if (await d.exists()) await walk(d, 0);
    }
    return out.toList()..sort();
  }

  /// 应用内文件选择对话框（电视遥控：方向键移动高亮、OK 选择）
  Future<String?> _pickFileDialog(List<String> files) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _TvFileDialog(files: files),
    );
  }

  void _applyM3U(String content, String label) {
    final channels = parseM3U(content);
    final groups = <String>{'全部'};
    for (final c in channels) {
      if (c.group.isNotEmpty) groups.add(c.group);
    }
    _update(() {
      _allChannels = channels;
      _groups = groups.toList();
      _group = '全部';
      _quality = '清晰';
      // 布局/列/行/预加载等 UI 偏好保留，不随新列表重置
      _page = 1;
      _loaded = true;
      _checking = false;
    });
    // 不保存：避免在 _restorePrefs 之前覆盖用户配置
    _showTip(L10n.t('已加载 $label（${channels.length} 路）', 'Loaded {label} ({n} channels)', {'label': label, 'n': channels.length}));
  }

  void _showTip(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
  }

  // ---------- 筛选与分页 ----------

  List<Channel> get _filtered => _allChannels.where((c) {
        final matchGroup = _group == '全部' || c.group == _group;
        final matchQuality =
            c.quality == '自动' || c.quality.isEmpty || c.quality == _quality;
        return matchGroup && matchQuality;
      }).toList();

  int get _totalPages {
    final n = _filtered.length;
    if (n == 0) return 1;
    return (n + _layout - 1) ~/ _layout;
  }

  List<Channel> get _pageChannels {
    final list = _filtered;
    final start = (_page - 1) * _layout;
    if (start >= list.length) return [];
    return list.sublist(start, min(start + _layout, list.length));
  }

  /// 预加载频道：当前页之后的连续 N 路（跨页），只建播放器不显示格子
  List<Channel> get _preloadChannels {
    if (_preload <= 0) return const [];
    final list = _filtered;
    final start = (_page - 1) * _layout + _layout;
    if (start >= list.length) return const [];
    final end = min(start + _preload, list.length);
    return list.sublist(start, end);
  }

  // ---------- 操作 ----------

  void _changeLayout(int n) {
    _update(() {
      _layout = n.clamp(1, 16).toInt();
      _page = 1;
      _poke();
    });
    _savePrefs();
  }

  void _changeColumns(int c) {
    _update(() {
      _columns = c.clamp(0, 4).toInt();
      _page = 1;
      _poke();
    });
    _savePrefs();
  }

  void _changeRows(int r) {
    _update(() {
      _rows = r.clamp(0, 4).toInt();
      _page = 1;
      _poke();
    });
    _savePrefs();
  }

  void _changePreload(int n) {
    _update(() {
      _preload = n.clamp(0, 8).toInt();
      _poke();
    });
    _savePrefs();
  }

  void _changeGroup(String g) {
    _update(() {
      _group = g;
      _page = 1;
      _gridFocusIndex = 0; // 切换分组后焦点回到第一个格子
      _poke();
    });
    _savePrefs();
  }

  /// 系统 LEANBACK 特性检测是否为电视
  Future<void> _detectTv() async {
    try {
      final isTv = await _tvChannel.invokeMethod<bool>('isTv') ?? false;
      if (mounted && _tvAuto != isTv) setState(() => _tvAuto = isTv);
    } catch (_) {}
  }

  /// 手动切换 TV 模式：auto/on/off
  void _setTvMode(String mode) {
    _update(() => _tvOverride = mode == 'auto' ? null : mode);
    _savePrefs();
  }

  /// 切换界面语言（跟随系统/中文/English），立即生效并持久化
  void _setLang(String key) {
    L10n.lang = L10n.langFrom(key);
    NativeIO.prefsSetString('lang', key);
    if (mounted) setState(() {});
  }

  /// 截图保存目录（高级设置里改，null=程序所在目录）
  void _setCaptureDir(String? dir) {
    _captureDir = (dir == null || dir.trim().isEmpty) ? null : dir.trim();
    _savePrefs();
    if (mounted) setState(() {});
  }

  /// 录制封装格式（只影响之后新开的录制，已在录的继续用原格式）
  void _setRecFormat(String f) {
    if (!_recordings.isEmpty) {
      _showTip(L10n.t('录制中不能切换封装格式，请先停止录制'));
      return;
    }
    _recFormat = f;
    _savePrefs();
    if (mounted) setState(() {});
  }

  /// 分段时长（分钟），0=不分段；录制中切换从下一段生效
  void _setRecSegment(int min) {
    _recSegmentMin = min.clamp(0, 240);
    _savePrefs();
    for (final rec in _recordings.values) {
      _scheduleSegment(rec);
    }
    if (mounted) setState(() {});
  }

  void _changeQuality(String q) {
    _update(() {
      _quality = q;
      _page = 1;
      _gridFocusIndex = 0; // 切换码流后焦点回到第一个格子
      _poke();
    });
    _savePrefs();
  }

  void _changeDecoder(String v) {
    setState(() => _videoDecoder = v);
    _savePrefs();
  }

  void _changeProbesize(int v) {
    setState(() => _probesize = v);
    _savePrefs();
  }

  void _changeAnalyzeduration(int v) {
    setState(() => _analyzeduration = v);
    _savePrefs();
  }

  void _changeNobuffer(bool v) {
    setState(() => _nobuffer = v);
    _savePrefs();
  }

  void _changeFlushPackets(bool v) {
    setState(() => _flushPackets = v);
    _savePrefs();
  }

  void _changeFirstFrameTimeout(int v) {
    setState(() => _firstFrameTimeout = v.clamp(1, 60).toInt());
    _savePrefs();
  }

  void _changeHeartbeatTimeout(int v) {
    setState(() => _heartbeatTimeout = v.clamp(1, 60).toInt());
    _savePrefs();
  }

  void _changeBufferSeconds(int v) {
    setState(() => _bufferSeconds = v.clamp(0, 10).toInt());
    _savePrefs();
  }

  void _changeReconnectDelayMax(int v) {
    setState(() => _reconnectDelayMax = v.clamp(1, 30).toInt());
    _savePrefs();
  }

  void _resetPrefs() {
    setState(() {
      // 播放器参数
      _videoDecoder = 'auto';
      _probesize = 32768;
      _analyzeduration = 20000;
      _nobuffer = true;
      _flushPackets = true;
      _firstFrameTimeout = 3;
      _heartbeatTimeout = 5;
      _bufferSeconds = 0;
      _reconnectDelayMax = 7;
      // 布局参数
      _layout = 2;
      _columns = 0;
      _rows = 0;
      _preload = 0;
      // 其他参数
      _quality = '清晰';
      // 方向重置跟随平台默认：Windows 默认横屏，其他平台默认竖屏
      _orientationLock = kIsDesktop ? 'landscape' : 'portrait';
      _tvOverride = null;
      _panelStyle = PanelStyle.auto;
    });
    _savePrefs();
    _applyOrientationLock();
  }

  void _changeOrientation(String v) {
    setState(() => _orientationLock = v == 'auto' ? null : v);
    _savePrefs();
    _applyOrientationLock();
  }

  bool _isSwitching = false; // 正在快速翻页切换中，期间不同步播放器池
  Timer? _pageDebounce;
  int _pendingPage = 0; // 防抖期间预览的页码（仅 UI 显示，不触发播放器）

  int get _displayPage => _pendingPage > 0 ? _pendingPage : _page;

  void _turnPage(int delta) {
    final tp = _totalPages;
    // 计算预览页码（用于 UI 即时显示）
    final base = _pendingPage > 0 ? _pendingPage : _page;
    final next = (base + delta).clamp(1, tp);
    if (next == _displayPage) return;
    // 进入切换状态：快速翻页期间不触发播放器同步
    _isSwitching = true;
    _pendingPage = next;
    _pageDebounce?.cancel();
    // 只更新 UI 显示页码，不调用 _update（避免触发 _reconcile）
    setState(() {});
    _poke();
    // 防抖 200ms：停止翻页后才真正更新 _page
    _pageDebounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      final tp = _totalPages;
      final finalPage = _pendingPage.clamp(1, tp);
      _pendingPage = 0;
      // 记录翻页前的页码：翻页方向必须和旧页码比，不能和已赋值的新页码比
      final prevPage = _page;
      if (finalPage != _page) {
        _page = finalPage;
      }
      // 再等 100ms 稳定后才加载播放器（期间不创建/销毁播放器）
      Timer(const Duration(milliseconds: 100), () {
        if (!mounted) return;
        _isSwitching = false;
        _lastStableChannels = _pageChannels; // 保存稳定页内容
        _reconcile();
        setState(() {});
        // 必须等新页布局完成后再跳：下一页 → 新页顶部；上一页 → 新页底部
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_gridScroll.hasClients) return;
          _gridScroll.jumpTo(
            finalPage > prevPage ? 0.0 : _gridScroll.position.maxScrollExtent,
          );
        });
      });
    });
  }

  // ---------- 信息条自动隐藏 ----------

  void _poke() {
    if (!mounted) return;
    setState(() => _infoVisible = true);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _infoVisible = false);
    });
  }

  // ---------- 面板 ----------

  bool get _panelIsLeft {
    if (_panelStyle == PanelStyle.left) return true;
    if (_panelStyle == PanelStyle.bottom) return false;
    // auto：竖屏底部，宽屏（横屏/电视）左侧
    return MediaQuery.of(context).orientation == Orientation.landscape;
  }

  void _togglePanel() {
    setState(() => _panelOpen = !_panelOpen);
    _poke();
  }

  void _setPanelStyle(PanelStyle s) {
    _update(() => _panelStyle = s);
    _savePrefs();
  }

  // ---------- 横竖屏 ----------

  Future<void> _applyOrientationLock() async {
    switch (_orientationLock) {
      case 'landscape':
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      case 'portrait':
        await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      default:
        await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
  }

  Future<void> _cycleOrientation() async {
    _orientationLock = switch (_orientationLock) {
      null => 'landscape',
      'landscape' => 'portrait',
      _ => null,
    };
    await _applyOrientationLock();
    _savePrefs();
    _showTip(switch (_orientationLock) {
      'landscape' => L10n.t('已切换横屏'),
      'portrait' => L10n.t('已切换竖屏'),
      _ => L10n.t('恢复自动旋转'),
    });
    _poke();
  }

  /// 进入系统画中画小窗（Android 8.0+；低版本提示不支持）
  Future<void> _enterPip() async {
    try {
      final ok = await _pipChannel.invokeMethod<bool>('enter');
      if (ok != true) _showTip(L10n.t('此设备不支持画中画（需 Android 8.0+）'));
    } catch (_) {
      _showTip(L10n.t('画中画不可用'));
    }
  }

  // ---------- 全局按键（电视遥控器） ----------
  // 硬件层统一捕获：方向键/OK/返回/菜单 不依赖焦点树，任何界面下都可靠

  bool _hardKey(KeyEvent event) {
    final k = event.logicalKey;
    // Windows 平台：ESC 退出全屏返回网格 / 关闭面板
    if (kIsDesktop && k == LogicalKeyboardKey.escape) {
      if (event is KeyRepeatEvent) return true; // 长按只触发一次
      if (event is! KeyDownEvent) return true;
      if (_fullscreenChannel != null) {
        // 录制中不能静默退出：交给全屏页的确认流程
        final req = _exitFullscreenRequest;
        if (req != null) {
          req();
        } else {
          _fullscreenChannel = null; // 立即清除，防止重复触发 pop
          Navigator.of(context).pop();
        }
        return true;
      }
      if (_panelOpen) {
        setState(() => _panelOpen = false);
        return true;
      }
      return false; // 未处理：留给对话框（如操作说明）按 ESC 关闭
    }
    // 返回键优先拦截：所有事件类型都拦，防止系统默认"按返回即退出应用"
    if (k == LogicalKeyboardKey.goBack) {
      if (event is KeyRepeatEvent) return true;
      final isRoot = !Navigator.of(context).canPop();
      if (!isRoot) return false; // 子页/对话框交给 Navigator
      if (event is KeyUpEvent) return true; // KeyUp 不重复处理
      if (_panelOpen) {
        setState(() => _panelOpen = false);
        return true;
      }
      final now = DateTime.now();
      if (_lastBackTs != null && now.difference(_lastBackTs!).inSeconds < 2) {
        SystemNavigator.pop();
        return true;
      }
      _lastBackTs = now;
      _showTip(L10n.t('再按一次返回键退出'));
      return true;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    final isRoot = !Navigator.of(context).canPop();
    // 菜单键：主界面切换面板（兼容 Android KEYCODE_MENU=82 映射差异）
    if (k == LogicalKeyboardKey.contextMenu ||
        event.logicalKey.keyId == 0x0010000d ||
        event.logicalKey.keyId == 0xFFFFFF05) {
      if (event is KeyRepeatEvent) return true; // 长按菜单只切换一次
      if (isRoot) _togglePanel();
      return true;
    }
    if (!isRoot) return false;
    // 空态：任意确认键/方向键直达文件选择
    if (_allChannels.isEmpty) {
      _importM3U();
      return true;
    }
    // 面板开着：方向键移动高亮、OK 激活
    if (_panelOpen) {
      if (k == LogicalKeyboardKey.arrowUp ||
          k == LogicalKeyboardKey.arrowDown ||
          k == LogicalKeyboardKey.arrowLeft ||
          k == LogicalKeyboardKey.arrowRight) {
        _panelKey.currentState
            ?.moveFocus((k == LogicalKeyboardKey.arrowDown ||
                    k == LogicalKeyboardKey.arrowRight)
                ? 1
                : -1);
        return true;
      }
      if (k == LogicalKeyboardKey.select ||
          k == LogicalKeyboardKey.enter ||
          k == LogicalKeyboardKey.space) {
        if (event is KeyRepeatEvent) return true; // 长按 OK 只激活一次
        _panelKey.currentState?.activateFocus();
        return true;
      }
      return false;
    }
    // 网格：方向键移动选中格、OK 进全屏
    final n = _pageChannels.length;
    if (n == 0) return false;
    if (k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight) {
      _poke();
      final cols = _gridColumns();
      var r = _gridFocusIndex ~/ cols;
      var c = _gridFocusIndex % cols;
      final rows = (n + cols - 1) ~/ cols;
      // 上下到边缘翻页（上一页/下一页），左右仅移动选中格
      if (k == LogicalKeyboardKey.arrowUp && r == 0) {
        _turnPage(-1);
        setState(() {
          final len = _pageChannels.length;
          _gridFocusIndex = ((len - 1) ~/ cols) * cols;
        });
        return true;
      }
      if (k == LogicalKeyboardKey.arrowDown && r == rows - 1) {
        _turnPage(1);
        setState(() => _gridFocusIndex = 0);
        return true;
      }
      if (k == LogicalKeyboardKey.arrowUp && r > 0) r--;
      if (k == LogicalKeyboardKey.arrowDown && r < rows - 1) r++;
      if (k == LogicalKeyboardKey.arrowLeft && c > 0) c--;
      if (k == LogicalKeyboardKey.arrowRight && c < cols - 1) c++;
      final ni = (r * cols + c).clamp(0, n - 1);
      setState(() => _gridFocusIndex = ni);
      return true;
    }
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.space) {
      if (event is KeyRepeatEvent) return true; // 长按 OK 只进一次全屏
      if (_gridFocusIndex < n) _openFullscreen(_pageChannels[_gridFocusIndex]);
      return true;
    }
    return false;
  }

  // 所有遥控按键已由硬件层 _hardKey 统一处理，此处不再重复拦截
  KeyEventResult _onGlobalKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      // Windows 平台：ESC 退出全屏返回网格 / 关闭面板
      if (kIsDesktop && event.logicalKey == LogicalKeyboardKey.escape) {
        if (_fullscreenChannel != null) {
          _fullscreenChannel = null;
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        if (_panelOpen) {
          setState(() => _panelOpen = false);
          return KeyEventResult.handled;
        }
      }
    }
    return KeyEventResult.ignored;
  }

  // ---------- 共享播放器池 ----------

  Set<String> _desiredUrls() {
    final set = <String>{};
    for (final c in _pageChannels) {
      set.add(c.url);
    }
    // 预加载：下一页的路数提前建好播放器，翻页即出画面
    for (final c in _preloadChannels) {
      set.add(c.url);
    }
    return set;
  }

  /// 同步池与当前页：创建缺失的、释放不再显示的（切换期间跳过，避免频繁重建崩溃）
  final Map<String, Timer> _destroyTimers = {};

  void _reconcile() {
    // 快速切换期间不同步播放器池，等稳定后再同步
    if (_isSwitching) return;
    // 快速翻页后稳定时，立即销毁所有旧播放器，不延迟
    _destroyTimers.forEach((k, t) => t.cancel());
    _destroyTimers.clear();
    final desired = _desiredUrls();
    // 先销毁所有不需要的播放器（立即销毁，不延迟）
    for (final u in _pool.keys.toList()) {
      if (!desired.contains(u)) {
        _destroy(u);
      }
    }
    // 再创建新页面的播放器
    for (final u in desired) {
      if (!_pool.containsKey(u)) _create(u);
    }
  }

  void _create(String url) {
    // 快速翻页期间不创建新播放器
    if (_isSwitching) return;
    final cfg = PlayerConfig(
      videoDecoder: _videoDecoder,
      probesize: _probesize,
      analyzeduration: _analyzeduration,
      nobuffer: _nobuffer,
      flushPackets: _flushPackets,
      bufferSeconds: _bufferSeconds,
      reconnectDelayMax: _reconnectDelayMax,
    );
    final c = NativePlayerController.networkUrl(Uri.parse(url), config: cfg);
    _pool[url] = c;
    _statuses[url] = L10n.t('连接中');
    c.setLooping(true);
    c.setVolume(0); // 网格默认静音
    c.addListener(() => _onControllerChanged(url));
    c.initialize().then((_) {
      // 快速翻页期间或播放器已被销毁，不执行
      if (!mounted || _isSwitching) {
        c.dispose();
        return;
      }
      if (_pool[url] != c) {
        c.dispose();
        return;
      }
      c.play();
      setState(() {});
      // 首帧兜底：open 成功后 5 秒内既无首帧也无错误（流不兼容/卡死），提示并重连
      _retryTimers[url]?.cancel();
      _retryTimers[url] = Timer(Duration(seconds: _firstFrameTimeout), () {
        if (!mounted) return;
        final cc = _pool[url];
        if (cc != null &&
            cc.value.isInitialized &&
            !cc.value.hasFrame &&
            !cc.value.hasError) {
          _statuses[url] = L10n.t('画面加载超时·重连中');
          setState(() {});
          _scheduleRetry(url);
        }
      });
    }).catchError((Object e) {
      // 初始化失败：由 hasError 监听触发重连
    });
  }

  void _destroy(String url) {
    if (_recordings.containsKey(url)) {
      // 画面被切走/关闭：先把录制停掉并保存，再销毁播放器
      unawaited(_stopRecording(url, notify: false).then((_) {
        if (mounted) _showTip(L10n.t('该路画面已切换，录制已停止并保存'));
      }));
    }
    _retryTimers[url]?.cancel();
    _retryTimers.remove(url);
    _retryPending.remove(url);
    final c = _pool.remove(url);
    _statuses.remove(url);
    // 快速翻页期间不 dispose，避免 native 层竞争
    if (c != null && !_isSwitching) {
      c.dispose();
    } else if (c != null) {
      // 快速翻页期间标记为待销毁，等稳定后再 dispose
      c.dispose();
    }
  }

  void _onControllerChanged(String url) {
    final c = _pool[url];
    if (c == null) return;
    if (c.value.hasError) {
      _statuses[url] = L10n.t('错误·重连中');
      if (mounted) setState(() {});
      _scheduleRetry(url);
      return;
    }
    if (c.value.isInitialized) {
      // 有首帧才算播放中；否则保持"连接中"（open 成功但还没出帧，画面由 native 渲染）
      _statuses[url] = c.value.hasFrame ? L10n.t('播放中') : L10n.t('连接中');
      if (mounted) setState(() {});
    }
  }

  void _scheduleRetry(String url) {
    if (_retryPending.contains(url)) return;
    _retryPending.add(url);
    _retryTimers[url]?.cancel();
    _retryTimers[url] = Timer(const Duration(seconds: 2), () {
      _retryPending.remove(url);
      _retryTimers.remove(url);
      if (!mounted) return;
      // 重建该路播放器
      _destroy(url);
      _create(url);
      setState(() {});
    });
  }

  String _statusOf(String url) => _statuses[url] ?? L10n.t('连接中');

  // ---------- 布局 ----------

  int _gridColumns() {
    if (_columns > 0) return _columns;
    // 指定了行数：列数 = 每行能放下 _layout 个的最小列数
    if (_rows > 0) return (_layout / _rows).ceil();
    final portrait =
        MediaQuery.of(context).orientation == Orientation.portrait;
    if (portrait) {
      switch (_layout) {
        case 1:
          return 1;
        case 2:
          return 1;
        case 4:
          return 2;
        case 8:
          return 2;
        case 16:
          return 2;
      }
    } else {
      switch (_layout) {
        case 1:
          return 1;
        case 2:
          return 2;
        case 4:
          return 2;
        case 8:
          return 4;
        case 16:
          return 4;
      }
    }
    return 2;
  }

  /// 实际网格行数：行布局指定则用之，否则按列数自动排
  int _gridRows() {
    if (_rows > 0) return _rows;
    return (_layout / _gridColumns()).ceil();
  }

  /// 格子宽高比：竖屏 1:1（可滚动）；横屏按布局动态填满屏幕，不出现滚动
  double _cellAspect() {
    final portrait =
        MediaQuery.of(context).orientation == Orientation.portrait;
    if (portrait) return 1.0;
    final cols = _gridColumns();
    final rows = _gridRows();
    final w = MediaQuery.of(context).size.width;
    final h = MediaQuery.of(context).size.height;
    return (w / cols) / (h / rows);
  }

  Future<void> _handleBack() async {
    // 面板开着：先关面板，不退出
    if (_panelOpen) {
      setState(() => _panelOpen = false);
      return;
    }
    // 连续两次返回才退出
    final now = DateTime.now();
    if (_lastBackTs != null && now.difference(_lastBackTs!).inSeconds < 2) {
      SystemNavigator.pop();
      return;
    }
    _lastBackTs = now;
    _showTip(L10n.t('再按一次返回键退出'));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: kIsDesktop
        ? DropTarget(
            onDragDone: (details) {
              if (details.files.isNotEmpty) {
                final file = details.files.first;
                _importM3UFromFile(file.path);
              }
            },
            child: Listener(
              onPointerDown: (_) => _poke(),
              child: Focus(
                autofocus: true,
                onKeyEvent: _onGlobalKey,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _loaded ? _buildGrid() : _buildLoading(),
                    // 面板打开时：全屏透明遮罩，点击面板外任意处 = 关闭面板
                    // （遮罩拦截视频点击，不会误入全屏；置于信息条/面板之下）
                    if (_panelOpen)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _panelOpen = false),
                        ),
                      ),
                    if (_infoVisible) _buildTopBar(),
                    if (_infoVisible && !_tvEffective) _buildBottomGroupBar(),
                    if (_panelOpen && _panelIsLeft) _buildLeftPanel(),
                    if (_panelOpen && !_panelIsLeft) _buildBottomPanel(),
                  ],
                ),
              ),
            ),
          )
        : Listener(
        onPointerDown: (_) => _poke(),
        child: Focus(
          autofocus: true,
          onKeyEvent: _onGlobalKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _loaded ? _buildGrid() : _buildLoading(),
              // 面板打开时：全屏透明遮罩，点击面板外任意处 = 关闭面板
              // （遮罩拦截视频点击，不会误入全屏；置于信息条/面板之下）
              if (_panelOpen)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _panelOpen = false),
                  ),
                ),
              if (_infoVisible) _buildTopBar(),
              if (_infoVisible && !_tvEffective) _buildBottomGroupBar(),
              if (_panelOpen && _panelIsLeft) _buildLeftPanel(),
              if (_panelOpen && !_panelIsLeft) _buildBottomPanel(),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildLoading() {
    if (_checking) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white70),
            SizedBox(height: 16),
            Text(L10n.t('正在加载上次的播放列表...'),
                style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.playlist_play, color: Colors.white38, size: 72),
          const SizedBox(height: 16),
          Text(L10n.t('未选择播放列表'),
              style: TextStyle(color: Colors.white70, fontSize: 17)),
          const SizedBox(height: 8),
          Text(L10n.t('请选择 M3U 文件后开始使用'),
              style: TextStyle(color: Colors.white38, fontSize: 13)),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.lightBlueAccent,
              foregroundColor: Colors.black,
            ),
            icon: const Icon(Icons.folder_open),
            label: Text(L10n.t('选择 M3U 文件')),
            onPressed: _importM3U,
          ),
        ],
      ),
    );
  }

  // ---------- 顶部信息条 ----------

  Widget _buildTopBar() {
    final safeTop = MediaQuery.of(context).padding.top;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 250),
        opacity: _infoVisible ? 1 : 0,
        child: IgnorePointer(
          ignoring: !_infoVisible,
          child: Container(
            padding: EdgeInsets.only(
                top: safeTop + 4, left: 8, right: 8, bottom: 6),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black87, Colors.transparent],
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: L10n.t('控制面板'),
                  icon: const Icon(Icons.menu, color: Colors.white, size: 22),
                  onPressed: _togglePanel,
                ),
                Expanded(
                  child: Text(
                    L10n.t('$_quality · 第 $_displayPage/$_totalPages 页', '{q} · Page {p}/{t}', {'q': _quality, 'p': _displayPage, 't': _totalPages}),
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: L10n.t('画中画'),
                  icon: const Icon(Icons.picture_in_picture_alt,
                      color: Colors.white, size: 20),
                  onPressed: _enterPip,
                ),
                IconButton(
                  tooltip: L10n.t('旋转屏幕'),
                  icon: Icon(
                    _orientationLock == 'landscape'
                        ? Icons.screen_lock_landscape
                        : _orientationLock == 'portrait'
                            ? Icons.screen_lock_portrait
                            : Icons.screen_rotation,
                    color: Colors.white,
                    size: 20,
                  ),
                  onPressed: _cycleOrientation,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 底部分组条（与顶部信息条同步自动隐藏） ----------

  Widget _buildBottomGroupBar() {
    final safeBottom = MediaQuery.of(context).padding.bottom;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !_infoVisible,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 250),
          opacity: _infoVisible ? 1 : 0,
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(0, 18, 0, safeBottom + 6),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black87, Colors.transparent],
              ),
            ),
            child: _GroupBar(
              groups: _groups,
              group: _group,
              onGroup: _changeGroup,
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 网格 ----------

  Widget _buildGrid() {
    // 快速翻页时，GridView 用新页的 channels（显示新页的8个框），框里只显示标题不创建播放器
    final channels = _pageChannels;
    if (channels.isEmpty) {
      return Center(
        child: Text(L10n.t('当前筛选无频道\n请打开面板切换分组/码流/翻页'),
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 15)),
      );
    }
    final cols = _gridColumns();
    return Listener(
      // 翻页手势用手动触摸位移判定，不依赖 ScrollNotification 的 velocity：
      // 内容不满屏/刚好满屏时 velocity 不稳定（旧方案在此场景失效），
      // 位移判定在任意内容高度下都可靠
      onPointerDown: (e) => _dragStartY = e.position.dy,
      onPointerUp: (e) => _maybePage(e.position.dy),
      onPointerCancel: (_) => _dragStartY = null,
      // Windows 鼠标滚轮：滚到顶部继续上滚=上一页，滚到底部继续下滚=下一页
      // 仅在网格（非全屏）状态生效；Android 触摸不产生 PointerScrollEvent，无影响
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) _handleWheel(e.scrollDelta.dy);
      },
      child: GridView.builder(
        controller: _gridScroll,
        padding: const EdgeInsets.all(2),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          crossAxisSpacing: 2,
          mainAxisSpacing: 2,
          childAspectRatio: _cellAspect(),
        ),
        itemCount: channels.length,
        itemBuilder: (context, i) {
          final ch = channels[i];
          return _MonitorCell(
            key: ValueKey('cell_${ch.url}'),
            channel: ch,
            controller: _pool[ch.url],
            status: _statusOf(ch.url),
            muted: true,
            // 选中框只在 TV 模式显示；手机/平板触摸操作不需要
            focused: _tvEffective && i == _gridFocusIndex,
            isSwitching: _isSwitching,
            recording: _isRecordingUrl(ch.url),
            onTap: () => _openFullscreen(ch),
            onMenu: (pos) => _showCellMenu(ch, pos),
          );
        },
      ),
    );
  }

  /// 翻页判定：位移足够大 + 当前滚动在边界
  /// 底部 + 手指上滑（dy<0）→ 下一页；顶部 + 手指下滑（dy>0）→ 上一页
  void _maybePage(double endY) {
    final start = _dragStartY;
    _dragStartY = null;
    if (start == null) return;
    final dy = endY - start;
    if (dy.abs() < 80) return; // 位移太小不算翻页
    if (!_gridScroll.hasClients) return;
    final pos = _gridScroll.position;
    final maxExtent = pos.maxScrollExtent;
    // 内容不满屏（maxScrollExtent <= 0），直接翻页
    if (maxExtent <= 0) {
      if (dy < -80) {
        _turnPage(1); // 下一页
      } else if (dy > 80) {
        _turnPage(-1); // 上一页
      }
      return;
    }
    // 内容超过屏幕，先滚到底部/顶部再翻页
    final atTop = pos.pixels <= 0;
    final atBottom = pos.pixels >= maxExtent;
    if (atBottom && dy < -80) {
      _turnPage(1); // 下一页
    } else if (atTop && dy > 80) {
      _turnPage(-1); // 上一页
    }
  }

  /// Windows 鼠标滚轮翻页：内容不满屏时直接翻页；
  /// 内容可滚动时，先滚到顶/底，继续滚动才翻页（与触摸翻页逻辑一致）
  void _handleWheel(double dy) {
    if (!mounted || !_gridScroll.hasClients) return;
    final pos = _gridScroll.position;
    final maxExtent = pos.maxScrollExtent;
    // 内容不满屏（maxScrollExtent <= 0），直接翻页
    if (maxExtent <= 0) {
      if (dy > 0) {
        _turnPage(1); // 滚轮下滚 = 下一页
      } else if (dy < 0) {
        _turnPage(-1); // 滚轮上滚 = 上一页
      }
      return;
    }
    final atTop = pos.pixels <= 0;
    final atBottom = pos.pixels >= maxExtent;
    if (dy > 0 && atBottom) {
      _turnPage(1); // 下一页
    } else if (dy < 0 && atTop) {
      _turnPage(-1); // 上一页
    }
  }

  void _openFullscreen(Channel channel) {
    _poke();
    final c = _pool[channel.url];
    c?.setVolume(1); // 全屏带声音
    _fullscreenChannel = channel; // Windows：ESC / 右键据此判断全屏状态
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => _FullscreenPage(
            channel: channel,
            controller: c,
            status: _statusOf(channel.url),
            onSnapshot: () => _captureScreenshot(channel),
            recording: _isRecordingUrl(channel.url),
            onToggleRecord: () async {
              if (_isRecordingUrl(channel.url)) {
                await _stopRecording(channel.url, notify: false);
                return false;
              }
              await _startRecording(channel);
              return _isRecordingUrl(channel.url);
            },
            onStopRecord: () =>
                _stopRecording(channel.url, notify: false),
            onRegisterExit: (fn) => _exitFullscreenRequest = fn,
            onClosed: () {
              c?.setVolume(0);
              _applyOrientationLock();
            },
          ),
        ))
        .then((_) {
      // 返回后保持原画面继续播放（同一 controller，无需重连）
      _fullscreenChannel = null;
      _exitFullscreenRequest = null;
      // 退出全屏后如果该路仍在录制（用户选了"继续录制"），提示仍在录
      if (_isRecordingUrl(channel.url) && mounted) {
        setState(() {});
        _showTip(L10n.t('该画面仍在后台录制，可在网格菜单中停止'));
      }
    });
  }

  /// 由全屏页注册：ESC / 右键统一走它的退出确认流程
  Future<void> Function()? _exitFullscreenRequest;

  /// 截取一路画面存成 PNG（设置里可指定桌面端保存目录）。
  /// 返回 path（成功）或 error 错误码（no_frame / PERMISSION_DENIED / SAVE_FAILED）
  Future<({String? path, String? error})> _captureScreenshot(
      Channel channel) async {
    final c = _pool[channel.url];
    if (c == null || !c.value.hasFrame) return (path: null, error: 'no_frame');
    try {
      final png = await c.snapshotPng();
      if (png == null) return (path: null, error: 'no_frame');
      final path = await CaptureStore.saveScreenshot(png, channel.name,
          customDir: _captureDir);
      return (path: path, error: null);
    } on PlatformException catch (e) {
      return (path: null, error: e.code);
    } catch (_) {
      return (path: null, error: 'SAVE_FAILED');
    }
  }

  /// 截图失败提示文案（按错误码给出可操作的说明）
  String _captureErrorText(String? code) => captureErrorText(code);

  /// 网格右键（桌面）/ 长按（手机）菜单
  Future<void> _showCellMenu(Channel channel, Offset globalPos) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final size = overlay?.size ?? MediaQuery.of(context).size;
    final pos = RelativeRect.fromLTRB(
      globalPos.dx,
      globalPos.dy,
      max(0, size.width - globalPos.dx),
      max(0, size.height - globalPos.dy),
    );
    final recording = _recordings.containsKey(channel.url);
    final sel = await showMenu<String>(
      context: context,
      position: pos,
      color: const Color(0xFF1E1E1E),
      items: [
        PopupMenuItem<String>(
          value: 'full',
          height: 38,
          child: Text(L10n.t('全屏'), style: const TextStyle(fontSize: 13)),
        ),
        PopupMenuItem<String>(
          value: 'shot',
          height: 38,
          child: Text(L10n.t('截图'), style: const TextStyle(fontSize: 13)),
        ),
        PopupMenuItem<String>(
          value: recording ? 'rec_stop' : 'rec_start',
          height: 38,
          child: Row(
            children: [
              Icon(
                recording ? Icons.stop_circle_outlined : Icons.fiber_manual_record,
                size: 15,
                color: recording ? Colors.white70 : Colors.redAccent,
              ),
              const SizedBox(width: 6),
              Text(recording ? L10n.t('停止录制') : L10n.t('开始录制'),
                  style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ],
    );
    if (!mounted || sel == null) return;
    switch (sel) {
      case 'full':
        _openFullscreen(channel);
      case 'shot':
        final r = await _captureScreenshot(channel);
        if (!mounted) return;
        _showTip(r.path != null
            ? L10n.t('截图已保存：${r.path}', 'Screenshot saved: {path}',
                {'path': r.path})
            : _captureErrorText(r.error));
      case 'rec_start':
        await _startRecording(channel);
      case 'rec_stop':
        await _stopRecording(channel.url);
    }
  }

  // ---------- 录制（单路：MDK 流复制，不重新解码） ----------

  bool _isRecordingUrl(String url) => _recordings.containsKey(url);

  /// 按画面实际编码决定封装格式（"自动"模式）。
  /// H.265(HEVC)：Windows 和 Android 上 MDK 都写不进 TS/MP4（只有一帧的废文件），
  /// 所以不分平台一律用 MKV。
  /// H.264：桌面用 TS（监控设备/NVR 通用），Android 用 MP4（相册能出缩略图）。
  String _resolveRecFormat(NativePlayerController c) {
    if (_recFormat != 'auto') return _recFormat;
    final codec = c.videoCodec.toLowerCase();
    final hevc = codec.contains('hevc') ||
        codec.contains('h265') ||
        codec.contains('h.265') ||
        codec.contains('265') ||
        codec.contains('hev1') ||
        codec.contains('hvc1');
    if (hevc) return 'mkv';
    if (Platform.isAndroid) return 'mp4';
    return 'ts';
  }

  Future<void> _startRecording(Channel channel) async {
    if (_recordings.containsKey(channel.url)) return;
    final c = _pool[channel.url];
    if (c == null || !c.value.isInitialized) {
      _showTip(L10n.t('该画面还没加载好，暂时不能录制'));
      return;
    }
    try {
      final fmt = _resolveRecFormat(c);
      final path = await CaptureStore.recordingPath(channel.name, _captureDir,
          part: 0, format: fmt);
      final ok = c.startRecord(path, format: fmt);
      if (!ok) {
        _showTip(L10n.t('录制启动失败，请稍后重试'));
        return;
      }
      final rec = _Recording(
        url: channel.url,
        name: channel.name,
        controller: c,
        part: 0,
        path: path,
        fmt: fmt,
        startedAt: DateTime.now(),
      );
      _recordings[channel.url] = rec;
      _scheduleSegment(rec);
      _scheduleCheck(rec);
      if (mounted) setState(() {});
      _showTip(L10n.t('已开始录制', 'Recording started'));
    } on PlatformException catch (e) {
      _showTip(e.code == 'PERMISSION_DENIED'
          ? L10n.t('需要存储权限才能保存录制文件，请在系统设置里允许本软件使用存储')
          : L10n.t('录制启动失败，请检查保存目录'));
    } catch (_) {
      _showTip(L10n.t('录制启动失败，请检查保存目录'));
    }
  }

  /// 某些源（如 HEVC 编码的 FLV/RTSP）在部分平台下 MDK 无法写入 TS / MP4：
  /// 只有容器头 + 一两帧（约 20KB），后续写入失败。
  /// 启动 3 秒后检查文件大小，若几乎没增长就自动改用 MKV 重新录，保证不丢内容。
  void _scheduleCheck(_Recording rec) {
    rec.checkTimer?.cancel();
    if (rec.fmt == 'mkv') return; // MKV 已是最稳格式，不再检测
    rec.checkTimer = Timer(const Duration(seconds: 3), () async {
      if (!rec.active || rec.fmt == 'mkv') return;
      final f = File(rec.path);
      final s1 = await f.exists() ? await f.length() : 0;
      await Future.delayed(const Duration(seconds: 2));
      if (!rec.active || rec.fmt == 'mkv') return;
      final s2 = await f.exists() ? await f.length() : 0;
      // 正常流 2 秒至少涨几 KB；若几乎不涨，说明 muxer 写入失败（只有容器头）
      if (s2 - s1 < 1024) await _fallbackToMkv(rec);
    });
  }

  Future<void> _fallbackToMkv(_Recording rec) async {
    final badPath = rec.path;
    try {
      rec.controller.stopRecord();
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 200));
    String next;
    try {
      next = await CaptureStore.recordingPath(rec.name, _captureDir,
          part: rec.part, format: 'mkv');
    } catch (_) {
      return;
    }
    if (!rec.controller.startRecord(next, format: 'mkv')) {
      return;
    }
    rec.path = next;
    rec.fmt = 'mkv';
    try {
      if (await File(badPath).exists()) await File(badPath).delete();
    } catch (_) {}
    _scheduleCheck(rec);
    if (mounted) setState(() {});
    _showTip(L10n.t(
        '当前画面无法用 TS/MP4 封装（该流编码不支持），已自动改用 MKV，画质无损',
        'This stream cannot be muxed into TS/MP4; switched to MKV (lossless)'));
  }

  /// 30 分钟（可配置）到点切下一段；录制不中断播放
  void _scheduleSegment(_Recording rec) {
    rec.timer?.cancel();
    if (_recSegmentMin <= 0) return;
    rec.timer = Timer(Duration(minutes: _recSegmentMin), () {
      _rotateSegment(rec);
    });
  }

  Future<void> _rotateSegment(_Recording rec) async {
    if (!rec.active || rec.controller.value.hasError) return;
    final prevPath = rec.path;
    try {
      rec.controller.stopRecord();
      final next = await CaptureStore.recordingPath(rec.name, _captureDir,
          part: rec.part + 1, format: rec.fmt);
      if (!rec.controller.startRecord(next, format: rec.fmt)) {
        _recordings.remove(rec.url);
        rec.active = false;
        if (mounted) setState(() {});
        _showTip(L10n.t('分段录制中断（画面可能已断开）'));
        return;
      }
      rec.part += 1;
      rec.path = next;
      rec.startedAt = DateTime.now();
      _scheduleSegment(rec);
      if (rec.fmt != 'mkv') _scheduleCheck(rec);
      _publishQuietly(prevPath, rec.part - 1, rec.fmt);
    } catch (_) {
      // 切换失败：保持原状，下一段再试
    }
  }

  /// 停止录制并把文件落到最终位置（Android：私有 → 公共下载目录）
  Future<void> _stopRecording(String url, {bool notify = true}) async {
    final rec = _recordings.remove(url);
    if (rec == null) return;
    rec.active = false;
    rec.timer?.cancel();
    rec.checkTimer?.cancel();
    rec.controller.stopRecord();
    if (mounted) setState(() {});
    final path = await _publishQuietly(rec.path, rec.part, rec.fmt);
    if (!notify) return;
    _showTip(path != null
        ? L10n.t('录制已保存：$path', 'Recording saved: {path}', {'path': path})
        : L10n.t('录制已停止，但保存到下载目录失败'));
  }

  /// 把一段录制文件发布到最终位置；返回可展示路径，失败返回 null
  Future<String?> _publishQuietly(String path, int part, [String? fmt]) async {
    final name = path.split(Platform.pathSeparator).last;
    try {
      return await CaptureStore.publishRecording(path, name, fmt ?? 'ts');
    } catch (_) {
      return null;
    }
  }

  // ---------- 面板容器 ----------

  Widget _buildLeftPanel() {
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: Container(
        width: 300,
        color: Colors.blueGrey.shade900.withValues(alpha: .97),
        child: SafeArea(
          child: _PanelBody(
            key: _panelKey,
            groups: _groups,
            group: _group,
            quality: _quality,
            layout: _layout,
            columns: _columns,
            rows: _rows,
            preload: _preload,
            page: _page,
            totalPages: _totalPages,
            panelStyle: _panelStyle,
            onClose: () => setState(() => _panelOpen = false),
            onLayout: _changeLayout,
            onColumns: _changeColumns,
            onRows: _changeRows,
            onPreload: _changePreload,
            onQuality: _changeQuality,
            onGroup: _changeGroup,
            onPage: _turnPage,
            onStyle: _setPanelStyle,
            onTvMode: _setTvMode,
            onLang: _setLang,
            captureDir: _captureDir,
            onCaptureDir: _setCaptureDir,
            recFormat: _recFormat,
            onRecFormat: _setRecFormat,
            recSegment: _recSegmentMin,
            onRecSegment: _setRecSegment,
            tvOverride: _tvOverride,
            onImport: _importM3U,
            videoDecoder: _videoDecoder,
            probesize: _probesize,
            analyzeduration: _analyzeduration,
            nobuffer: _nobuffer,
            flushPackets: _flushPackets,
            onDecoder: _changeDecoder,
            onProbesize: _changeProbesize,
            onAnalyzeduration: _changeAnalyzeduration,
            onNobuffer: _changeNobuffer,
            onFlushPackets: _changeFlushPackets,
            firstFrameTimeout: _firstFrameTimeout,
            heartbeatTimeout: _heartbeatTimeout,
            bufferSeconds: _bufferSeconds,
            onFirstFrameTimeout: _changeFirstFrameTimeout,
            onHeartbeatTimeout: _changeHeartbeatTimeout,
            onBufferSeconds: _changeBufferSeconds,
            reconnectDelayMax: _reconnectDelayMax,
            onReconnectDelayMax: _changeReconnectDelayMax,
            onReset: _resetPrefs,
            orientationLock: _orientationLock,
            onOrientation: _changeOrientation,
          ),
        ),
      ),
    );
  }

  Widget _buildBottomPanel() {
    final h = MediaQuery.of(context).size.height * 0.58;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        height: h.clamp(260.0, 560.0),
        decoration: BoxDecoration(
          color: Colors.blueGrey.shade900.withValues(alpha: .97),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          top: false,
          child: _PanelBody(
            key: _panelKey,
            groups: _groups,
            group: _group,
            quality: _quality,
            layout: _layout,
            columns: _columns,
            rows: _rows,
            preload: _preload,
            page: _page,
            totalPages: _totalPages,
            panelStyle: _panelStyle,
            onClose: () => setState(() => _panelOpen = false),
            onLayout: _changeLayout,
            onColumns: _changeColumns,
            onRows: _changeRows,
            onPreload: _changePreload,
            onQuality: _changeQuality,
            onGroup: _changeGroup,
            onPage: _turnPage,
            onStyle: _setPanelStyle,
            onTvMode: _setTvMode,
            onLang: _setLang,
            captureDir: _captureDir,
            onCaptureDir: _setCaptureDir,
            recFormat: _recFormat,
            onRecFormat: _setRecFormat,
            recSegment: _recSegmentMin,
            onRecSegment: _setRecSegment,
            tvOverride: _tvOverride,
            onImport: _importM3U,
            videoDecoder: _videoDecoder,
            probesize: _probesize,
            analyzeduration: _analyzeduration,
            nobuffer: _nobuffer,
            flushPackets: _flushPackets,
            onDecoder: _changeDecoder,
            onProbesize: _changeProbesize,
            onAnalyzeduration: _changeAnalyzeduration,
            onNobuffer: _changeNobuffer,
            onFlushPackets: _changeFlushPackets,
            firstFrameTimeout: _firstFrameTimeout,
            heartbeatTimeout: _heartbeatTimeout,
            bufferSeconds: _bufferSeconds,
            onFirstFrameTimeout: _changeFirstFrameTimeout,
            onHeartbeatTimeout: _changeHeartbeatTimeout,
            onBufferSeconds: _changeBufferSeconds,
            reconnectDelayMax: _reconnectDelayMax,
            onReconnectDelayMax: _changeReconnectDelayMax,
            onReset: _resetPrefs,
            orientationLock: _orientationLock,
            onOrientation: _changeOrientation,
          ),
        ),
      ),
    );
  }
}

/// 操作说明弹窗（首次启动指引 / 控制面板内入口共用）
Future<void> showHelpDialog(BuildContext context, {bool dismissible = true}) {
  return showDialog(
    context: context,
    barrierDismissible: dismissible,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.blueGrey.shade900,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Text(L10n.t('M3U播放器 · 操作说明'),
          style: TextStyle(color: Colors.white, fontSize: 16)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _helpSection(L10n.t('基本操作'), [
              '',
              L10n.t('【打开 / 关闭控制面板】'),
              L10n.t('手机：点击屏幕中间区域，或点击顶部按钮'),
              L10n.t('电视：按遥控器菜单键 MENU'),
              '',
              L10n.t('【翻页】'),
              L10n.t('手机：网格模式下，手指上滑=下一页，下滑=上一页'),
              L10n.t('电视：按左右方向键，或用控制面板的翻页按钮'),
              '',
              L10n.t('【切换分组】'),
              L10n.t('手机：底部半透明条左右滑动选择分组'),
              L10n.t('电视：控制面板里选择分组'),
              '',
              L10n.t('【切换码流】'),
              L10n.t('控制面板里选择：清晰 / 流畅'),
              '',
              L10n.t('【切换布局】'),
              L10n.t('控制面板里用加减按钮调节：同时加载数量（1~16路）'),
              L10n.t('还可以用加减按钮调节：列布局、行布局（1~4列/行）'),
            ]),
            // Windows 电脑版专属操作说明（仅 Windows 显示，Android/TV 不显示）
            if (kIsDesktop) ...[
              const SizedBox(height: 10),
              _helpSection(L10n.t('电脑版（Windows / Linux）'), [
                '',
                L10n.t('【打开 / 关闭控制面板】'),
                L10n.t('点击左上角菜单按钮'),
                '',
                L10n.t('【进入全屏】'),
                L10n.t('双击某个视频画面'),
                '',
                L10n.t('【退出全屏】'),
                L10n.t('按 ESC 键，或点击鼠标右键'),
                '',
                L10n.t('【翻页】'),
                L10n.t('鼠标滚轮向下滚 = 下一页，向上滚 = 上一页'),
                L10n.t('列表可滚动时：滚到底部继续下滚 = 下一页，滚到顶部继续上滚 = 上一页'),
                '',
                L10n.t('【加载播放列表】'),
                L10n.t('直接把 M3U 文件拖进窗口即可'),
                L10n.t('也可以打开控制面板点击"加载 M3U 文件"'),
                '',
                L10n.t('【键盘】'),
                L10n.t('方向键移动选中，Enter / 空格进入全屏'),
                '',
                L10n.t('【配置保存】'),
                L10n.t('所有修改自动保存到软件目录下的 config.ini，下次启动恢复'),
              ]),
            ],
            const SizedBox(height: 10),
            _helpSection(L10n.t('全屏模式'), [
              '',
              L10n.t('【进入全屏】'),
              L10n.t('手机：双击某个视频画面'),
              L10n.t('电视：方向键选中后按 OK 键'),
              '',
              L10n.t('【退出全屏】'),
              L10n.t('手机：再双击一次，或按系统返回键'),
              L10n.t('电视：按返回键'),
              '',
              L10n.t('【全屏内缩放】'),
              L10n.t('手机：双指捏合放大缩小，最大 8 倍'),
              L10n.t('电视：暂不支持缩放'),
              '',
              L10n.t('【全屏内旋转】'),
              L10n.t('手机：双击全屏画面，在横屏 / 竖屏之间切换'),
              '',
              L10n.t('【全屏声音】'),
              L10n.t('进入全屏后自动打开声音，退出后静音'),
            ]),
            const SizedBox(height: 10),
            _helpSection(L10n.t('返回键行为'), [
              '',
              L10n.t('【按一次返回键】'),
              L10n.t('如果控制面板打开：关闭控制面板'),
              L10n.t('如果在全屏模式：退出全屏'),
              L10n.t('如果在主界面：提示再按一次退出'),
              '',
              L10n.t('【快速按两次返回键】'),
              L10n.t('在主界面快速按两次，直接退出软件'),
            ]),
            const SizedBox(height: 10),
            _helpSection(L10n.t('电视遥控器'), [
              '',
              L10n.t('方向键：移动选中焦点'),
              L10n.t('OK / 确认键：进入选中的画面'),
              L10n.t('菜单键 MENU：打开 / 关闭控制面板'),
              L10n.t('返回键：关闭面板 · 退出全屏 · 退出软件'),
            ]),
            const SizedBox(height: 10),
            _helpSection(L10n.t('画面提示'), [
              '',
              L10n.t('顶部信息条 3 秒自动隐藏，轻触唤出'),
              L10n.t('底部半透明条为分组，左右滑动切换'),
              L10n.t('控制面板：布局 / 码流 / 预加载 / 翻页 / 参数设置'),
              L10n.t('所有修改的设置会自动保存，下次打开生效'),
              L10n.t('点重置所有参数可以恢复默认设置'),
            ]),
            const SizedBox(height: 10),
            _helpSection(L10n.t('M3U 分组 / 码流设置'), [
              L10n.t('分组 = group-title 的值，如 group-title="教室1;清晰"'),
              L10n.t('分号 ; 后面的就是码流名（清晰 / 流畅，可自定义）'),
              L10n.t('URL 结尾 _0 = 清晰(HEVC)、_1 = 流畅(H.264)'),
              L10n.t('一个频道只识别第一个 group-title'),
              L10n.t('没有分组标记的频道归入"全部"'),
            ]),
            const SizedBox(height: 10),
            _helpSection(L10n.t('播放器参数（调完翻页生效）'), [
              '',
              L10n.t('【解码方式】'),
              L10n.t('自动：自动选择硬解或软解，推荐默认'),
              L10n.t('硬解：GPU硬件解码，占用CPU低，播放流畅'),
              L10n.t('软解：CPU软件解码，兼容性好，占用CPU高'),
              L10n.t('如果硬解黑屏或卡顿，切到软试试'),
              '',
              L10n.t('【探测大小】avformat.probesize'),
              L10n.t('识别流格式的缓存大小，单位字节'),
              L10n.t('越小：首帧出得快，但可能识别不全导致失败'),
              L10n.t('越大：识别准确，但首帧出得慢'),
              L10n.t('推荐：32K（32768），网络好可以 8K'),
              '',
              L10n.t('【分析时长】avformat.analyzeduration'),
              L10n.t('解码分析流信息的时间，单位微秒'),
              L10n.t('越小：首帧出得快，但可能丢帧或卡顿'),
              L10n.t('越大：分析充分，播放稳定，但首帧慢'),
              L10n.t('推荐：20ms（20000微秒）'),
              '',
              L10n.t('【低延迟 nobuffer】avformat.fflags=+nobuffer'),
              L10n.t('FFmpeg 低延迟开关，不缓冲直接播放'),
              L10n.t('开启：延迟低，但网络抖动时容易卡顿'),
              L10n.t('关闭：有缓冲，播放更平滑，延迟高一点'),
              L10n.t('监控场景推荐：开启'),
              '',
              '【flush flush_packets】avformat.fflags=+flush_packets',
              L10n.t('清缓冲降延迟，每次出包立即播放'),
              L10n.t('和 nobuffer 配合使用，进一步降低延迟'),
              '',
              L10n.t('【首帧超时】'),
              L10n.t('打开流后，多少秒没出首帧就判定失败，自动重连'),
              L10n.t('推荐：3秒，网络差可以调到 5~10 秒'),
              '',
              L10n.t('【心跳超时】'),
              L10n.t('出首帧后，多少秒没新帧就判定僵死，自动重连'),
              L10n.t('推荐：5秒，监控流稳定，5秒没新帧说明断了'),
              '',
              L10n.t('【缓冲秒数】setBufferRange'),
              L10n.t('fvp 播放器缓冲机制，缓冲多少秒再播放'),
              L10n.t('0：不缓冲，低延迟，和 nobuffer 配合'),
              L10n.t('2~5秒：缓冲几秒，播放更稳定，延迟高'),
              L10n.t('注意：不要和 nobuffer 同时开'),
              L10n.t('  低延迟方案：nobuffer=开，缓冲秒数=0'),
              L10n.t('  稳定优先方案：nobuffer=关，缓冲秒数=2~5'),
              '',
              L10n.t('【重连最大间隔】avio.reconnect_delay_max'),
              L10n.t('网络断开后，自动重连的最大等待时间'),
              L10n.t('推荐：7秒，不要太小，避免频繁重连'),
            ]),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(L10n.t('知道了'),
              style: TextStyle(color: Colors.lightBlueAccent, fontSize: 15)),
        ),
      ],
    ),
  );
}

Widget _helpSection(String title, List<String> lines) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title,
          style: const TextStyle(
              color: Colors.lightBlueAccent,
              fontSize: 14,
              fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      for (final l in lines)
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Text('· $l', style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ),
    ],
  );
}

/// 关于弹窗：版本信息 + 组件架构构成 + 作者
Future<void> showAppAboutDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.blueGrey.shade900,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Text(L10n.t('关于'),
          style: TextStyle(color: Colors.white, fontSize: 16)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _aboutRow(L10n.t('应用名称'), kAppName),
            _aboutRow(L10n.t('版本'), '$kAppVersion（build $kAppBuild）'),
            _aboutRow(L10n.t('作者'), kAppAuthor),
            _aboutRow(L10n.t('许可'), kAppLicense),
            const SizedBox(height: 10),
            Text(L10n.t('组件架构构成'),
                style: TextStyle(
                    color: Colors.lightBlueAccent,
                    fontSize: 14,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            for (final l in [
              L10n.t('Flutter 3.47.4 / Dart 3.13.3（UI 框架）'),
              L10n.t('fvp 0.38.1（MDK 多媒体内核）'),
              L10n.t('FFmpeg（HEVC-in-FLV / H.264 硬解与软解）'),
              L10n.t('平台：Android（arm64-v8a / armeabi-v7a / x86_64）'),
              L10n.t('平台：Windows（x64 桌面版）'),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text('· $l',
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 13)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(L10n.t('知道了'),
              style: TextStyle(color: Colors.lightBlueAccent, fontSize: 15)),
        ),
      ],
    ),
  );
}

Widget _aboutRow(String key, String value) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$key：',
            style: const TextStyle(color: Colors.white54, fontSize: 13)),
        Expanded(
          child: Text(value,
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ),
      ],
    ),
  );
}

/// 底部分组条：单行横向滑动，点击后自动滚动保持选中项可见
class _GroupBar extends StatefulWidget {
  final List<String> groups;
  final String group;
  final ValueChanged<String> onGroup;

  const _GroupBar({
    required this.groups,
    required this.group,
    required this.onGroup,
  });

  @override
  State<_GroupBar> createState() => _GroupBarState();
}

class _GroupBarState extends State<_GroupBar> {
  final ScrollController _c = ScrollController();
  final Map<String, GlobalKey> _keys = {};

  @override
  void initState() {
    super.initState();
    // 唤出时定位到当前选中分组（分组条每次显示都会重建）
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _scrollToCurrent() {
    final key = _keys[widget.group];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: Duration.zero,
        alignment: 0.5,
      );
    }
  }

  void _select(String g) {
    widget.onGroup(g);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: ListView(
        controller: _c,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        children: [
          for (final g in widget.groups)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _chip(g, _keys[g] ??= GlobalKey()),
            ),
        ],
      ),
    );
  }

  Widget _chip(String g, GlobalKey key) {
    final selected = g == widget.group;
    return KeyedSubtree(
      key: key,
      child: InkWell(
        onTap: () => _select(g),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? Colors.lightBlueAccent.withValues(alpha: .55)
                : Colors.black45,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? Colors.lightBlueAccent : Colors.white24,
            ),
          ),
          child: Text(
            g,
            style: TextStyle(
              fontSize: 13,
              color: selected ? Colors.white : Colors.white70,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}

/// 面板内容：独立 StatefulWidget，父页面 rebuild 时滚动位置/内部状态不重置
class _PanelBody extends StatefulWidget {
  final List<String> groups;
  final String group;
  final String quality;
  final int layout;
  final int columns;
  final int rows;
  final int preload;
  final int page;
  final int totalPages;
  final PanelStyle panelStyle;
  final VoidCallback onClose;
  final ValueChanged<int> onLayout;
  final ValueChanged<int> onColumns;
  final ValueChanged<int> onRows;
  final ValueChanged<int> onPreload;
  final ValueChanged<String> onQuality;
  final ValueChanged<String> onGroup;
  final String? tvOverride;
  final ValueChanged<String> onTvMode;
  final ValueChanged<String> onLang;
  // 高级设置：截图/录制保存目录（null=程序所在目录）
  final String? captureDir;
  final ValueChanged<String?> onCaptureDir;
  // 高级设置：录制参数
  final String recFormat; // ts / mkv / mp4
  final ValueChanged<String> onRecFormat;
  final int recSegment; // 分段时长（分钟），0=不分段
  final ValueChanged<int> onRecSegment;
  final ValueChanged<int> onPage;
  final ValueChanged<PanelStyle> onStyle;
  final VoidCallback onImport;
  // 播放器参数
  final String videoDecoder;
  final int probesize;
  final int analyzeduration;
  final bool nobuffer;
  final bool flushPackets;
  final ValueChanged<String> onDecoder;
  final ValueChanged<int> onProbesize;
  final ValueChanged<int> onAnalyzeduration;
  final ValueChanged<bool> onNobuffer;
  final ValueChanged<bool> onFlushPackets;
  final int firstFrameTimeout;
  final int heartbeatTimeout;
  final int bufferSeconds;
  final ValueChanged<int> onFirstFrameTimeout;
  final ValueChanged<int> onHeartbeatTimeout;
  final ValueChanged<int> onBufferSeconds;
  final int reconnectDelayMax;
  final ValueChanged<int> onReconnectDelayMax;
  final VoidCallback onReset;
  // 方向锁定
  final String? orientationLock;
  final ValueChanged<String> onOrientation;

  const _PanelBody({
    super.key,
    required this.groups,
    required this.group,
    required this.quality,
    required this.layout,
    required this.columns,
    required this.rows,
    required this.preload,
    required this.page,
    required this.totalPages,
    required this.panelStyle,
    required this.onClose,
    required this.onLayout,
    required this.onColumns,
    required this.onRows,
    required this.onPreload,
    required this.onQuality,
    required this.onGroup,
    required this.tvOverride,
    required this.onTvMode,
    required this.onLang,
    required this.captureDir,
    required this.onCaptureDir,
    required this.recFormat,
    required this.onRecFormat,
    required this.recSegment,
    required this.onRecSegment,
    required this.onPage,
    required this.onStyle,
    required this.onImport,
    required this.videoDecoder,
    required this.probesize,
    required this.analyzeduration,
    required this.nobuffer,
    required this.flushPackets,
    required this.onDecoder,
    required this.onProbesize,
    required this.onAnalyzeduration,
    required this.onNobuffer,
    required this.onFlushPackets,
    required this.firstFrameTimeout,
    required this.heartbeatTimeout,
    required this.bufferSeconds,
    required this.onFirstFrameTimeout,
    required this.onHeartbeatTimeout,
    required this.onBufferSeconds,
    required this.reconnectDelayMax,
    required this.onReconnectDelayMax,
    required this.onReset,
    required this.orientationLock,
    required this.onOrientation,
  });

  @override
  State<_PanelBody> createState() => _PanelBodyState();
}

class _PanelBodyState extends State<_PanelBody> {
  // 电视遥控：面板内可交互按钮的焦点索引（父组件硬件层驱动）
  int _focusIndex = 0;
  final List<VoidCallback> _actions = <VoidCallback>[];
  final List<GlobalKey> _btnKeys = <GlobalKey>[];

  /// 遥控：方向键移动焦点（并滚动面板让焦点按钮可见）
  void moveFocus(int delta) {
    if (_actions.isEmpty) return;
    setState(() {
      _focusIndex = (_focusIndex + delta + _actions.length) % _actions.length;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_focusIndex < _btnKeys.length) {
        final ctx = _btnKeys[_focusIndex]?.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 180),
            alignment: 0.35,
          );
        }
      }
    });
  }

  /// 遥控：激活当前焦点按钮
  void activateFocus() {
    if (_actions.isNotEmpty && _focusIndex < _actions.length) {
      _actions[_focusIndex]();
    }
  }

  @override
  Widget build(BuildContext context) {
    _actions.clear();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(L10n.t('控制面板'),
                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
              ),
              IconButton(
                tooltip: L10n.t('面板样式'),
                icon: const Icon(Icons.swap_horiz, color: Colors.white70, size: 20),
                onPressed: () => widget.onStyle(switch (widget.panelStyle) {
                  PanelStyle.auto => PanelStyle.left,
                  PanelStyle.left => PanelStyle.bottom,
                  PanelStyle.bottom => PanelStyle.auto,
                }),
              ),
              IconButton(
                tooltip: L10n.t('关闭'),
                icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                onPressed: widget.onClose,
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Colors.white24),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label(L10n.t('同时加载数量')),
                _stepperRow(
                  L10n.t('${widget.layout} 路', '{n} ch', {'n': widget.layout}),
                  widget.layout,
                  1,
                  16,
                  widget.onLayout,
                ),
                const SizedBox(height: 10),
                _label(L10n.t('列布局')),
                _stepperRow(
                  widget.columns == 0 ? L10n.t('自动') : L10n.t('${widget.columns}列', '{n} cols', {'n': widget.columns}),
                  widget.columns,
                  0,
                  4,
                  widget.onColumns,
                ),
                const SizedBox(height: 10),
                _label(L10n.t('行布局')),
                _stepperRow(
                  widget.rows == 0 ? L10n.t('自动') : L10n.t('${widget.rows}行', '{n} rows', {'n': widget.rows}),
                  widget.rows,
                  0,
                  4,
                  widget.onRows,
                ),
                const SizedBox(height: 10),
                _label(L10n.t('预加载下一页')),
                _stepperRow(L10n.t('${widget.preload} 路', '{n} ch', {'n': widget.preload}), widget.preload, 0, 8, widget.onPreload),
                const SizedBox(height: 10),
                _label(L10n.t('码流')),
                Wrap(
                  spacing: 6,
                  runSpacing: 8,
                  children: [
                    _btn('清晰', widget.quality == '清晰', () => widget.onQuality('清晰')),
                    _btn('流畅', widget.quality == '流畅', () => widget.onQuality('流畅')),
                  ],
                ),
                const SizedBox(height: 10),
                _label(L10n.t('分组')),
                Wrap(
                  spacing: 6,
                  runSpacing: 8,
                  children: [
                    for (final g in widget.groups)
                      _btn(g, g == widget.group, () => widget.onGroup(g)),
                  ],
                ),
                const SizedBox(height: 12),
                _label(L10n.t('翻页')),
                Row(
                  children: [
                    _btn(L10n.t('上一页'), false, () => widget.onPage(-1)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        L10n.t('第 ${widget.page} / ${widget.totalPages} 页', 'Page {p} / {t}', {'p': widget.page, 't': widget.totalPages}),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _btn(L10n.t('下一页'), false, () => widget.onPage(1)),
                  ],
                ),
                const SizedBox(height: 10),
                const Divider(color: Colors.white24),
                _label(L10n.t('面板样式')),
                Wrap(
                  spacing: 6,
                  runSpacing: 8,
                  children: [
                    for (final s in PanelStyle.values) ...[
                      _btn(
                        switch (s) {
                          PanelStyle.auto => L10n.t('自动'),
                          PanelStyle.left => L10n.t('左侧'),
                          PanelStyle.bottom => L10n.t('底部'),
                        },
                        widget.panelStyle == s,
                        () => widget.onStyle(s),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                const Divider(color: Colors.white24),
                _label(L10n.t('TV 模式')),
                Wrap(
                  spacing: 6,
                  runSpacing: 8,
                  children: [
                    _btn(L10n.t('自动'), widget.tvOverride == null, () => widget.onTvMode('auto')),
                    _btn(L10n.t('开启'), widget.tvOverride == 'on', () => widget.onTvMode('on')),
                    _btn(L10n.t('关闭'), widget.tvOverride == 'off', () => widget.onTvMode('off')),
                  ],
                ),
                const SizedBox(height: 10),
                const Divider(color: Colors.white24),
                // 界面语言已移到"高级设置"页，与截图/录制设置统一收纳
                _label(L10n.t('播放器参数（调完翻页生效，自动保存）')),
                _label(L10n.t('解码方式')),
                Wrap(
                  spacing: 6,
                  runSpacing: 8,
                  children: [
                    _btn(L10n.t('自动'), widget.videoDecoder == 'auto', () => widget.onDecoder('auto')),
                    _btn(L10n.t('硬解'), widget.videoDecoder == 'mediacodec', () => widget.onDecoder('mediacodec')),
                    _btn(L10n.t('软解'), widget.videoDecoder == 'software', () => widget.onDecoder('software')),
                  ],
                ),
                Text(L10n.t('硬解=GPU解码快，软解=CPU解码稳，自动=两者切换'),
                    style: TextStyle(fontSize: 10, color: Colors.white38)),
                const SizedBox(height: 10),
                _label(L10n.t('探测大小')),
                Wrap(
                  spacing: 6,
                  runSpacing: 8,
                  children: [
                    _btn('8K', widget.probesize == 8192, () => widget.onProbesize(8192)),
                    _btn('32K', widget.probesize == 32768, () => widget.onProbesize(32768)),
                    _btn('64K', widget.probesize == 65536, () => widget.onProbesize(65536)),
                    _btn('128K', widget.probesize == 131072, () => widget.onProbesize(131072)),
                  ],
                ),
                Text(L10n.t('探测大小=识别流格式的缓存，越小越快但可能不稳定'),
                    style: TextStyle(fontSize: 10, color: Colors.white38)),
                const SizedBox(height: 10),
                _label(L10n.t('分析时长')),
                Wrap(
                  spacing: 6,
                  runSpacing: 8,
                  children: [
                    _btn('10ms', widget.analyzeduration == 10000, () => widget.onAnalyzeduration(10000)),
                    _btn('20ms', widget.analyzeduration == 20000, () => widget.onAnalyzeduration(20000)),
                    _btn('50ms', widget.analyzeduration == 50000, () => widget.onAnalyzeduration(50000)),
                    _btn('100ms', widget.analyzeduration == 100000, () => widget.onAnalyzeduration(100000)),
                  ],
                ),
                Text(L10n.t('分析时长=解码分析流的时间，越小越快但可能丢帧'),
                    style: TextStyle(fontSize: 10, color: Colors.white38)),
                const SizedBox(height: 10),
                _label(L10n.t('低延迟')),
                Wrap(
                  spacing: 6,
                  runSpacing: 8,
                  children: [
                    _btn('nobuffer', widget.nobuffer, () => widget.onNobuffer(!widget.nobuffer)),
                    _btn('flush', widget.flushPackets, () => widget.onFlushPackets(!widget.flushPackets)),
                  ],
                ),
                Text(L10n.t('nobuffer=不缓冲直接播放，flush=清缓冲降延迟'),
                    style: TextStyle(fontSize: 10, color: Colors.white38)),
                const SizedBox(height: 10),
                _label(L10n.t('首帧超时（秒）')),
                _stepperRow('${widget.firstFrameTimeout}', widget.firstFrameTimeout, 1, 60, widget.onFirstFrameTimeout),
                Text(L10n.t('首帧最大等待时间，超时重连'),
                    style: TextStyle(fontSize: 10, color: Colors.white38)),
                const SizedBox(height: 10),
                _label(L10n.t('心跳超时（秒）')),
                _stepperRow('${widget.heartbeatTimeout}', widget.heartbeatTimeout, 1, 60, widget.onHeartbeatTimeout),
                Text(L10n.t('出首帧后无新帧判定僵死'),
                    style: TextStyle(fontSize: 10, color: Colors.white38)),
                const SizedBox(height: 10),
                _label(L10n.t('缓冲秒数')),
                _stepperRow('${widget.bufferSeconds}', widget.bufferSeconds, 0, 10, widget.onBufferSeconds),
                Text(L10n.t('缓冲多少秒再播放，0=不缓冲'),
                    style: TextStyle(fontSize: 10, color: Colors.white38)),
                const SizedBox(height: 10),
                _label(L10n.t('重连最大间隔（秒）')),
                _stepperRow('${widget.reconnectDelayMax}', widget.reconnectDelayMax, 1, 30, widget.onReconnectDelayMax),
                Text(L10n.t('网络断开后自动重连的最大等待时间'),
                    style: TextStyle(fontSize: 10, color: Colors.white38)),
                const SizedBox(height: 10),
                const Divider(color: Colors.white24),
                _label(L10n.t('屏幕方向')),
                Wrap(
                  spacing: 6,
                  runSpacing: 8,
                  children: [
                    _btn(L10n.t('自动'), widget.orientationLock == null, () => widget.onOrientation('auto')),
                    _btn(L10n.t('竖屏'), widget.orientationLock == 'portrait', () => widget.onOrientation('portrait')),
                    _btn(L10n.t('横屏'), widget.orientationLock == 'landscape', () => widget.onOrientation('landscape')),
                  ],
                ),
                const SizedBox(height: 14),
                Center(
                  child: _btn(L10n.t('加载 M3U 文件'), false, widget.onImport),
                ),
                const SizedBox(height: 10),
                Center(
                  child: _btn(L10n.t('高级设置'), false, _openAdvanced),
                ),
                const SizedBox(height: 10),
                Center(
                  child: _btn(L10n.t('操作说明'), false,
                      () => showHelpDialog(context)),
                ),
                const SizedBox(height: 10),
                Center(
                  child: _btn(L10n.t('关于'), false, () => showAppAboutDialog(context)),
                ),
                const SizedBox(height: 10),
                const SizedBox(height: 10),
                Center(
                  child: _btn(L10n.t('重置所有参数'), false, widget.onReset),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 高级设置页：界面语言 + 截图/录制保存位置 + 录制参数
  Future<void> _openAdvanced() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _AdvancedSheet(
        captureDir: widget.captureDir,
        onCaptureDir: widget.onCaptureDir,
        langKey: L10n.langKey(),
        onLang: widget.onLang,
        recFormat: widget.recFormat,
        onRecFormat: widget.onRecFormat,
        recSegment: widget.recSegment,
        onRecSegment: widget.onRecSegment,
      ),
    );
  }

  Widget _label(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text,
          style: const TextStyle(fontSize: 12, color: Colors.white54)),
    );
  }

  /// 加减步进行：通用数量调节（列布局、预加载等）
  Widget _stepperRow(String display, int value, int min, int max,
      ValueChanged<int> onChanged) {
    return Row(
      children: [
        _btn('−', false, () => onChanged(value - 1),
            enabled: value > min),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            display,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ),
        const SizedBox(width: 8),
        _btn('＋', false, () => onChanged(value + 1),
            enabled: value < max),
      ],
    );
  }

  Widget _btn(String label, bool selected, VoidCallback onTap,
      {bool enabled = true}) {
    final idx = _actions.length;
    _actions.add(enabled ? onTap : () {});
    while (_btnKeys.length <= idx) _btnKeys.add(GlobalKey());
    final focused = idx == _focusIndex;
    return InkWell(
      key: _btnKeys[idx],
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(6),
      focusColor: Colors.lightBlueAccent.withValues(alpha: .22),
      onFocusChange: (v) => setState(() {}),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: !enabled
              ? Colors.transparent
              : selected
                  ? Colors.lightBlueAccent.withValues(alpha: .35)
                  : Colors.white10,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: focused
                ? Colors.amber
                : !enabled
                    ? Colors.white10
                    : selected
                        ? Colors.lightBlueAccent
                        : Colors.white24,
            width: focused ? 2.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: !enabled
                ? Colors.white24
                : selected
                    ? Colors.lightBlueAccent.shade100
                    : Colors.white70,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

/// 单个画面格子：遥控器焦点选中框 + 状态角标
/// 播放器由页面级共享池注入，格子本身不创建/销毁播放器。
class _MonitorCell extends StatefulWidget {
  final Channel channel;
  final NativePlayerController? controller;
  final String status;
  final bool muted;
  final bool focused;
  final bool isSwitching;
  /// 该路是否正在录制（左上角显示红点）
  final bool recording;
  final VoidCallback onTap;
  /// 右键（桌面）/ 长按（手机）呼出菜单，传入按下的全局坐标
  final void Function(Offset globalPos)? onMenu;

  const _MonitorCell({
    super.key,
    required this.channel,
    required this.controller,
    required this.status,
    required this.muted,
    required this.focused,
    required this.isSwitching,
    required this.recording,
    required this.onTap,
    this.onMenu,
  });

  @override
  State<_MonitorCell> createState() => _MonitorCellState();
}

class _MonitorCellState extends State<_MonitorCell> {
  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    // open 成功即显示画面（native 直接渲染到 Texture，不依赖事件通道；
    // 若 8 秒无首帧，由页面级兜底提示并重连）
    // 出首帧才算有画面；open 成功但无帧时显示"连接中/加载中"提示（不黑屏无提示）
    final showFrame = c != null && c.value.hasFrame;
    final focused = widget.focused;
    return GestureDetector(
      onDoubleTap: widget.onTap, // 双击进入全屏（单击不响应，避免误触）
      // 右键（Windows/Linux 鼠标）/ 长按（Android）呼出操作菜单
      onSecondaryTapDown: (d) => widget.onMenu?.call(d.globalPosition),
      onLongPressStart: (d) => widget.onMenu?.call(d.globalPosition),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black,
          border: Border.all(
            color: focused ? Colors.amber : Colors.white12,
            width: focused ? 3 : 1,
          ),
        ),
        child: Stack(
                fit: StackFit.expand,
                children: [
                  // 快速翻页时，不显示转圈/连接中，只显示标题
                  if (showFrame && !widget.isSwitching)
                    Center(
                      child: AspectRatio(
                        aspectRatio: c.value.aspectRatio,
                        child: NativeVideoPlayer(controller: c),
                      ),
                    ),
                  if (!showFrame && !widget.isSwitching)
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 26,
                            height: 26,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5, color: Colors.white70),
                          ),
                          const SizedBox(height: 8),
                          Text(widget.status,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 11)),
                        ],
                      ),
                    ),
                  // 频道名
                  Positioned(
                    left: 5,
                    bottom: 4,
                    right: 5,
                    child: Text(
                      widget.channel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                      ),
                    ),
                  ),
                  // 录制中标记：左上角闪烁红点 + REC
                  if (widget.recording)
                    Positioned(
                      left: 6,
                      top: 5,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                              color: Colors.redAccent,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(color: Colors.black54, blurRadius: 3),
                              ],
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Text(
                            'REC',
                            style: TextStyle(
                              color: Colors.redAccent,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              shadows: [
                                Shadow(color: Colors.black, blurRadius: 3),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        );
  }
}

/// 全屏单画面：复用网格同一播放器（不重新加载），带声音 + 双指缩放 + 手动横屏
class _FullscreenPage extends StatefulWidget {
  final Channel channel;
  final NativePlayerController? controller;
  final String status;
  final VoidCallback onClosed;
  /// 截图：返回 path（成功）或 error 错误码（失败）
  final Future<({String? path, String? error})> Function()? onSnapshot;
  /// 当前是否在录制（进入全屏时的状态）
  final bool recording;
  /// 切换录制状态，返回切换后的状态
  final Future<bool> Function()? onToggleRecord;
  /// 停止录制（退出确认里"停止录制并退出"用）
  final Future<void> Function()? onStopRecord;
  /// 注册"请求退出全屏"入口，供主页 ESC / 右键统一走确认流程
  final void Function(Future<void> Function()?)? onRegisterExit;

  const _FullscreenPage({
    required this.channel,
    required this.controller,
    required this.status,
    required this.onClosed,
    this.onSnapshot,
    this.recording = false,
    this.onToggleRecord,
    this.onStopRecord,
    this.onRegisterExit,
  });

  @override
  State<_FullscreenPage> createState() => _FullscreenPageState();
}

class _FullscreenPageState extends State<_FullscreenPage> {
  final TransformationController _tc = TransformationController();
  String? _lock; // null=当前方向，双击切横屏/竖屏
  late bool _rec = widget.recording;

  @override
  @override
  void initState() {
    super.initState();
    // 全屏时隐藏状态栏和导航栏
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    widget.onRegisterExit?.call(_requestExit);
  }

  @override
  void dispose() {
    widget.onRegisterExit?.call(null);
    _tc.dispose();
    // 退出全屏时恢复状态栏和导航栏
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    widget.onClosed(); // 恢复网格静音 + 恢复主页面方向
    super.dispose();
  }

  Future<void> _applyLock(String? l) async {
    switch (l) {
      case 'landscape':
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      case 'portrait':
        await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      default:
        await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
  }

  /// 双击：横屏全屏 <-> 竖屏
  Future<void> _cycleLock() async {
    _lock = _lock == 'landscape' ? 'portrait' : 'landscape';
    await _applyLock(_lock);
    if (mounted) setState(() {});
  }

  /// 角落截图按钮：点了才截，平时几乎不可见（低透明度小圆钮）
  Future<void> _onSnapshotTap() async {
    final fn = widget.onSnapshot;
    if (fn == null) return;
    final r = await fn();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(r.path != null
            ? L10n.t('截图已保存：${r.path}', 'Screenshot saved: {path}',
                {'path': r.path})
            : captureErrorText(r.error)),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
  }

  /// 角落录制按钮：开始/停止本路录制
  Future<void> _onRecordTap() async {
    final fn = widget.onToggleRecord;
    if (fn == null) return;
    final now = await fn();
    if (!mounted) return;
    setState(() => _rec = now);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(now
            ? L10n.t('已开始录制', 'Recording started')
            : L10n.t('录制已停止并保存', 'Recording stopped and saved')),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
  }

  /// 退出全屏统一入口：录制中必须由用户确认如何处理录制
  Future<void> _requestExit() async {
    if (!mounted) return;
    if (!_rec) {
      Navigator.of(context).pop();
      return;
    }
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(L10n.t('正在录制', 'Recording in progress'),
            style: const TextStyle(fontSize: 16, color: Colors.white)),
        content: Text(
          L10n.t('退出全屏前请先确认：停止录制，或在后台继续录制。',
              'Please confirm what to do with the recording before leaving.'),
          style: const TextStyle(fontSize: 13, color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: Text(L10n.t('取消', 'Cancel'),
                style: const TextStyle(fontSize: 13)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('keep'),
            child: Text(L10n.t('继续录制并退出', 'Keep recording'),
                style: const TextStyle(fontSize: 13)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop('stop'),
            child: Text(L10n.t('停止录制并退出', 'Stop and exit'),
                style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'stop':
        await widget.onStopRecord?.call();
        if (mounted) {
          setState(() => _rec = false);
          Navigator.of(context).pop();
        }
      case 'keep':
        Navigator.of(context).pop();
      default:
        break; // 取消：留在全屏继续录制
    }
  }

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.of(context).padding.top;
    final c = widget.controller;
    // 出首帧才算有画面；open 成功但无帧时显示加载提示
    final showFrame = c != null && c.value.hasFrame;
    return PopScope(
      canPop: !_rec, // 录制中拦下系统返回键，走确认框
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestExit();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Listener(
        // Windows：鼠标右键退出全屏返回网格（Android 触摸无右键，不受影响）
        onPointerDown: (e) {
          if ((e.buttons & kSecondaryMouseButton) != 0) {
            _requestExit();
          }
        },
        child: GestureDetector(
        // 返回用系统返回键（默认导航行为），单击不响应
        onDoubleTap: _cycleLock,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (showFrame)
              InteractiveViewer(
                transformationController: _tc,
                minScale: 1,
                maxScale: 8,
                clipBehavior: Clip.none,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: c.value.aspectRatio,
                    child: NativeVideoPlayer(controller: c),
                  ),
                ),
              )
            else
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(
                          strokeWidth: 3, color: Colors.white70),
                    ),
                    const SizedBox(height: 12),
                    Text(widget.status,
                        style: const TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
            // 全屏模式不显示标题和提示，保持纯净画面
            // 仅在右上角放一个低调的截图按钮（半透明、小尺寸）
            if (widget.onSnapshot != null)
              Positioned(
                right: 10,
                top: 10 + safeTop,
                child: Opacity(
                  opacity: 0.38,
                  child: Material(
                    color: Colors.black54,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _onSnapshotTap,
                      child: Padding(
                        padding: const EdgeInsets.all(7),
                        child: Icon(Icons.camera_alt_outlined,
                            size: 17,
                            color: Colors.white70,
                            semanticLabel: L10n.t('截图')),
                      ),
                    ),
                  ),
                ),
              ),
            // 录制按钮：放在截图按钮左侧，同样低调；录制中变红色
            if (widget.onToggleRecord != null)
              Positioned(
                right: 10 + 31 + 8,
                top: 10 + safeTop,
                child: Opacity(
                  opacity: _rec ? 0.85 : 0.38,
                  child: Material(
                    color: Colors.black54,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _onRecordTap,
                      child: Padding(
                        padding: const EdgeInsets.all(7),
                        child: Icon(
                          _rec
                              ? Icons.stop_circle_outlined
                              : Icons.fiber_manual_record,
                          size: 17,
                          color: _rec ? Colors.redAccent : Colors.white70,
                          semanticLabel:
                              _rec ? L10n.t('停止录制') : L10n.t('开始录制'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      ),
      ),
    );
  }
}

/// 单路录制状态：一路一个，随页面销毁时停止并保存
class _Recording {
  _Recording({
    required this.url,
    required this.name,
    required this.controller,
    required this.part,
    required this.path,
    required this.fmt,
    required this.startedAt,
  });

  final String url;
  final String name;
  final NativePlayerController controller;
  int part; // 分段序号（0 为第一段）
  String path; // 当前分段文件路径
  String fmt; // 当前段实际使用的封装格式（可能因自检降级从 ts 变成 mkv）
  DateTime startedAt;
  Timer? timer;
  Timer? checkTimer;
  bool active = true;
}

/// 应用内文件列表选择框（电视遥控友好：方向键移动高亮、OK 选择）
class _TvFileDialog extends StatefulWidget {
  final List<String> files;
  const _TvFileDialog({required this.files});

  @override
  State<_TvFileDialog> createState() => _TvFileDialogState();
}

class _TvFileDialogState extends State<_TvFileDialog> {
  int _index = 0;
  final ScrollController _sc = ScrollController();

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _index = (_index + (k == LogicalKeyboardKey.arrowDown ? 1 : -1) +
                widget.files.length) %
            widget.files.length;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_sc.hasClients) {
          final target = (_index * 50.0)
              .clamp(0.0, _sc.position.maxScrollExtent);
          _sc.animateTo(target,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut);
        }
      });
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.space) {
      Navigator.of(context).pop(widget.files[_index]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.blueGrey.shade900,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Text(L10n.t('选择 M3U 文件'),
          style: TextStyle(color: Colors.white, fontSize: 16)),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: ListView.builder(
            controller: _sc,
            itemCount: widget.files.length,
            itemBuilder: (context, i) {
              final focused = i == _index;
              final name = widget.files[i].split('/').last;
              return InkWell(
                onTap: () => Navigator.of(context).pop(widget.files[i]),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    color: focused
                        ? Colors.lightBlueAccent.withValues(alpha: .25)
                        : Colors.transparent,
                    border: Border.all(
                      color: focused ? Colors.amber : Colors.transparent,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    name,
                    style: TextStyle(
                      color: focused ? Colors.white : Colors.white70,
                      fontSize: 15,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              );
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L10n.t('取消'),
              style: TextStyle(color: Colors.lightBlueAccent, fontSize: 14)),
        ),
      ],
    );
  }
}

/// 高级设置页（控制面板内弹出）：界面语言 + 截图/录制保存位置
///
/// 语言与截图/录制设置集中放在这里，主面板保持精简。
class _AdvancedSheet extends StatefulWidget {
  final String? captureDir;
  final ValueChanged<String?> onCaptureDir;
  final String langKey;
  final ValueChanged<String> onLang;
  final String recFormat;
  final ValueChanged<String> onRecFormat;
  final int recSegment;
  final ValueChanged<int> onRecSegment;

  const _AdvancedSheet({
    required this.captureDir,
    required this.onCaptureDir,
    required this.langKey,
    required this.onLang,
    required this.recFormat,
    required this.onRecFormat,
    required this.recSegment,
    required this.onRecSegment,
  });

  @override
  State<_AdvancedSheet> createState() => _AdvancedSheetState();
}

class _AdvancedSheetState extends State<_AdvancedSheet> {
  late String _lang;
  late String? _dir;
  late String _recFormat;
  late int _recSegment;
  String? _appDir;

  @override
  void initState() {
    super.initState();
    _lang = widget.langKey;
    _dir = widget.captureDir;
    _recFormat = widget.recFormat;
    _recSegment = widget.recSegment;
    NativeIO.getAppDir().then((d) {
      if (mounted) setState(() => _appDir = d);
    });
  }

  Widget _sec(String text) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Text(text,
            style: const TextStyle(
                fontSize: 13,
                color: Colors.white70,
                fontWeight: FontWeight.w600)),
      );

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(text,
            style: const TextStyle(fontSize: 11, color: Colors.white38)),
      );

  Widget _pill(String label, bool selected, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? Colors.lightBlueAccent.withValues(alpha: .35)
                : Colors.white10,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(label,
              style: const TextStyle(color: Colors.white, fontSize: 13)),
        ),
      );

  void _setLang(String key) {
    _lang = key;
    widget.onLang(key);
    if (mounted) setState(() {});
  }

  Future<void> _pickDir() async {
    final d = await NativeIO.pickDirectory();
    if (d == null || d.trim().isEmpty) return;
    _dir = d.trim();
    widget.onCaptureDir(_dir);
    if (mounted) setState(() {});
  }

  Future<void> _openDir() async {
    final base = _dir ?? _appDir;
    if (base == null) return;
    await NativeIO.openDirectory('$base${Platform.pathSeparator}screenshots');
  }

  Future<void> _openRecDir() async {
    final base = _dir ?? _appDir;
    if (base == null) return;
    await NativeIO.openDirectory('$base${Platform.pathSeparator}recordings');
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.75;
    final baseText = _dir ?? _appDir ?? '…';
    return Dialog(
      backgroundColor: Colors.blueGrey.shade900,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 460, maxHeight: maxH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 8, 10),
              child: Row(
                children: [
                  const Icon(Icons.tune, size: 18, color: Colors.lightBlueAccent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(L10n.t('高级设置'),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18, color: Colors.white54),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white24),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sec(L10n.t('界面语言')),
                    Wrap(
                      spacing: 6,
                      runSpacing: 8,
                      children: [
                        _pill(L10n.t('跟随系统'), _lang == 'system',
                            () => _setLang('system')),
                        _pill('中文', _lang == 'zh', () => _setLang('zh')),
                        _pill('English', _lang == 'en', () => _setLang('en')),
                      ],
                    ),
                    _hint(L10n.t('默认跟随系统语言，切换后立即生效并自动保存')),

                    const SizedBox(height: 18),
                    const Divider(color: Colors.white24),
                    _sec(L10n.t('截图与录制')),
                    Text(L10n.t('截图保存位置'),
                        style:
                            const TextStyle(fontSize: 12, color: Colors.white54)),
                    const SizedBox(height: 4),
                    SelectableText(
                      kIsDesktop
                          ? '$baseText${Platform.pathSeparator}screenshots'
                          : '${L10n.t('下载')}/M3U播放器/screenshots',
                      style: const TextStyle(fontSize: 12, color: Colors.white),
                    ),
                    if (kIsDesktop) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 8,
                        children: [
                          _pill(L10n.t('更改目录'), false, _pickDir),
                          _pill(L10n.t('恢复默认'), _dir == null, () {
                            _dir = null;
                            widget.onCaptureDir(null);
                            if (mounted) setState(() {});
                          }),
                          _pill(L10n.t('打开文件夹'), false, _openDir),
                        ],
                      ),
                      _hint(L10n.t('默认保存在软件所在目录，留空即使用默认')),
                    ] else
                      _hint(L10n.t('Android 上直接保存到"下载/M3U播放器"，可在文件管理器查看')),

                    const SizedBox(height: 16),
                    Text(L10n.t('录制保存位置'),
                        style:
                            const TextStyle(fontSize: 12, color: Colors.white54)),
                    const SizedBox(height: 4),
                    SelectableText(
                      kIsDesktop
                          ? '$baseText${Platform.pathSeparator}recordings'
                          : '${L10n.t('下载')}/M3U播放器/recordings',
                      style: const TextStyle(fontSize: 12, color: Colors.white),
                    ),
                    if (kIsDesktop) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 8,
                        children: [
                          _pill(L10n.t('打开录制文件夹'), false, _openRecDir),
                        ],
                      ),
                    ],
                    _hint(L10n.t('录制文件与截图放在同一个根目录下，分 screenshots / recordings 两个子目录')),

                    const SizedBox(height: 16),
                    Text(L10n.t('录制封装格式'),
                        style:
                            const TextStyle(fontSize: 12, color: Colors.white54)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 8,
                      children: [
                        _pill(L10n.t('自动', 'Auto'), _recFormat == 'auto', () {
                          _recFormat = 'auto';
                          widget.onRecFormat('auto');
                          if (mounted) setState(() {});
                        }),
                        _pill('TS', _recFormat == 'ts', () {
                          _recFormat = 'ts';
                          widget.onRecFormat('ts');
                          if (mounted) setState(() {});
                        }),
                        _pill('MKV', _recFormat == 'mkv', () {
                          _recFormat = 'mkv';
                          widget.onRecFormat('mkv');
                          if (mounted) setState(() {});
                        }),
                        _pill('MP4', _recFormat == 'mp4', () {
                          _recFormat = 'mp4';
                          widget.onRecFormat('mp4');
                          if (mounted) setState(() {});
                        }),
                      ],
                    ),
                    _hint(L10n.t(
                        '自动（推荐）：H.264 用 TS（Windows/Linux，监控设备通用）或 MP4（Android，相册能出缩略图）；H.265 一律用 MKV——Windows 和 Android 都写不进 TS/MP4',
                        'Auto (recommended): H.264 → TS on desktop, MP4 on Android; H.265 always MKV (TS/MP4 fail on Windows and Android)')),
                    _hint(L10n.t('手动选 TS/MP4 遇到不支持的流时，几秒内会自动改用 MKV 并提示，画质不受影响')),

                    const SizedBox(height: 16),
                    Text(L10n.t('分段时长'),
                        style:
                            const TextStyle(fontSize: 12, color: Colors.white54)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 8,
                      children: [
                        for (final m in const [15, 30, 60])
                          _pill(L10n.t('$m 分钟', '$m min'),
                              _recSegment == m, () {
                            _recSegment = m;
                            widget.onRecSegment(m);
                            if (mounted) setState(() {});
                          }),
                        _pill(L10n.t('不分段', 'No split'), _recSegment == 0, () {
                          _recSegment = 0;
                          widget.onRecSegment(0);
                          if (mounted) setState(() {});
                        }),
                      ],
                    ),
                    _hint(L10n.t('到点自动换新文件，单段过大会影响播放和拷贝；默认 30 分钟')),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: Colors.white24),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
              child: Align(
                alignment: Alignment.centerRight,
                child: _pill(L10n.t('完成'), true,
                    () => Navigator.of(context).pop()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
