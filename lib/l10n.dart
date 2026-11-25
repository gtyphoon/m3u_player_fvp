import 'dart:io';

/// 界面语言支持：跟随系统（默认）/ 中文 / English。
///
/// 语言选择持久化在 config.ini 的 lang 键：
///   system = 跟随系统（Windows/Android 系统语言是英文则界面英文）
///   zh     = 强制中文
///   en     = 强制英文
///
/// 用法：
///   Text(S.t('加载 M3U 文件'))
///   动态拼接：S.t('已加载 $label（${channels.length} 路）',
///             'Loaded {label} ({n} channels)', {'label': label, 'n': channels.length})
enum AppLang { system, zh, en }

class L10n {
  static AppLang lang = AppLang.system;

  static String langKey() => switch (lang) {
        AppLang.system => 'system',
        AppLang.zh => 'zh',
        AppLang.en => 'en',
      };

  static AppLang langFrom(String? key) => switch (key) {
        'zh' => AppLang.zh,
        'en' => AppLang.en,
        _ => AppLang.system,
      };

  /// 系统语言是否为英文（Windows / Android 均可用）
  static bool get _systemIsEn {
    try {
      return Platform.localeName.toLowerCase().startsWith('en');
    } catch (_) {
      return false;
    }
  }

  /// 当前是否显示英文
  static bool get isEn => switch (lang) {
        AppLang.en => true,
        AppLang.zh => false,
        AppLang.system => _systemIsEn,
      };

  /// 取界面文案：中文原文为 key，英文通过 en 参数或 _en 表查得；
  /// 动态串把中文里的 $var / ${expr} 统一换成 {var} 后再填参数。
  static String t(String zh, [String? en, Map<String, Object?>? args]) {
    var template = isEn ? (en ?? _en[zh] ?? zh) : zh;
    if (args == null || args.isEmpty) return template;
    template = template.replaceAllMapped(
      RegExp(r'\$\{(\w+)\}|\$(\w+)'),
      (m) => '{${m.group(1) ?? m.group(2)}}',
    );
    for (final e in args.entries) {
      template = template.replaceAll('{${e.key}}', '${e.value}');
    }
    return template;
  }

  /// 中 -> 英 翻译表（key 为中文原文）
  static const Map<String, String> _en = {
    // ---------- 应用/关于 ----------
    'M3U播放器': 'M3U Player',
    '应用名称': 'App Name',
    '版本': 'Version',
    '作者': 'Author',
    '许可': 'License',
    '关于': 'About',
    '组件架构构成': 'Component Architecture',
    'Flutter 3.47.4 / Dart 3.13.3（UI 框架）':
        'Flutter 3.47.4 / Dart 3.13.3 (UI framework)',
    'fvp 0.38.1（MDK 多媒体内核）': 'fvp 0.38.1 (MDK multimedia core)',
    'FFmpeg（HEVC-in-FLV / H.264 硬解与软解）':
        'FFmpeg (HEVC-in-FLV / H.264 hardware & software decode)',
    '平台：Android（arm64-v8a / armeabi-v7a / x86_64）':
        'Platform: Android (arm64-v8a / armeabi-v7a / x86_64)',
    '平台：Windows（x64 桌面版）': 'Platform: Windows (x64 desktop)',
    '知道了': 'Got it',
    '取消': 'Cancel',

    // ---------- 截图 / 高级设置 ----------
    '截图': 'Snapshot',
    '全屏': 'Fullscreen',
    '高级设置': 'Advanced',
    '截图与录制': 'Snapshots & Recording',
    '截图保存位置': 'Snapshot folder',
    '更改目录': 'Change folder',
    '恢复默认': 'Use default',
    '打开文件夹': 'Open folder',
    '下载': 'Downloads',
    '截图已保存': 'Screenshot saved',
    '截图失败，可能暂无画面': 'Snapshot failed — no picture yet',
    '暂无画面，无法截图': 'No picture to capture',
    '默认跟随系统语言，切换后立即生效并自动保存':
        'Follows system language by default; changes apply instantly and are saved.',
    '默认保存在软件所在目录，留空即使用默认':
        'Default is the app folder; leave it unset to keep the default.',
    'Android 上直接保存到"下载/M3U播放器"，可在文件管理器查看':
        'On Android files go to Downloads/M3U播放器 and are visible in the file manager.',
    '录制保存位置': 'Recording folder',
    '打开录制文件夹': 'Open recording folder',
    '录制封装格式': 'Recording container',
    '分段时长': 'Segment length',
    '不分段': 'No split',
    '分钟': 'min',
    'TS 为流复制、最省性能且断流也能播放；MP4 需等停止后才完整，兼容性最好':
        'TS is stream-copied, cheapest and still playable if interrupted; MP4 is most compatible but only complete after stopping.',
    '到点自动换新文件，单段过大会影响播放和拷贝；默认 30 分钟':
        'A new file starts automatically; huge files are slow to play and copy. Default 30 min.',
    '录制文件与截图放在同一个根目录下，分 screenshots / recordings 两个子目录':
        'Recording and snapshot files share one root folder, under screenshots / recordings.',
    '开始录制': 'Start recording',
    '停止录制': 'Stop recording',
    '已开始录制': 'Recording started',
    '录制已停止并保存': 'Recording stopped and saved',
    '正在录制': 'Recording in progress',
    '退出全屏前请先确认：停止录制，或在后台继续录制。':
        'Confirm what happens to the recording before leaving fullscreen.',
    '继续录制并退出': 'Keep recording',
    '停止录制并退出': 'Stop and exit',
    '该画面仍在后台录制，可在网格菜单中停止':
        'Still recording in background — stop it from the grid menu.',
    '该画面还没加载好，暂时不能录制':
        'Picture not ready yet — cannot record right now.',
    '录制启动失败，请稍后重试': 'Failed to start recording, please retry.',
    '录制启动失败，请检查保存目录':
        'Failed to start recording — check the save folder.',
    '需要存储权限才能保存录制文件，请在系统设置里允许本软件使用存储':
        'Storage permission is required to save recordings. Allow it in system settings.',
    '该路画面已切换，录制已停止并保存':
        'Channel switched — recording stopped and saved.',
    '分段录制中断（画面可能已断开）':
        'Segment recording interrupted (connection may have dropped).',
    '录制已停止，但保存到下载目录失败':
        'Recording stopped, but saving to Downloads failed.',
    '录制中不能切换封装格式，请先停止录制':
        'Stop recording before changing the container format.',
    '完成': 'Done',

    // ---------- 加载与提示 ----------
    '上次选择': 'Last loaded',
    '文件内容为空': 'File is empty',
    '未识别到有效频道，请检查 M3U 格式':
        'No valid channels found. Check the M3U format.',
    
    
    
    
    '需要存储权限才能读取 M3U 文件':
        'Storage permission is required to read the M3U file.',
    '未找到 M3U 文件，请放到 /sdcard/Download 或 /sdcard 根目录':
        'No M3U file found. Put it in /sdcard/Download or the /sdcard root.',
    '再按一次返回键退出': 'Press back again to exit',
    '正在加载上次的播放列表...': 'Loading last playlist...',
    '未选择播放列表': 'No playlist selected',
    '请选择 M3U 文件后开始使用': 'Select an M3U file to start',
    '选择 M3U 文件': 'Select M3U File',
    '当前筛选无频道\n请打开面板切换分组/码流/翻页':
        'No channels match the filter\nOpen the panel to switch group / quality / page',
    '加载 M3U 文件': 'Load M3U File',

    // ---------- 状态 ----------
    '连接中': 'Connecting',
    '播放中': 'Playing',
    '画面加载超时·重连中': 'Frame timeout · Reconnecting',
    '错误·重连中': 'Error · Reconnecting',

    // ---------- 方向/画中画 ----------
    '已切换横屏': 'Switched to landscape',
    '已切换竖屏': 'Switched to portrait',
    '恢复自动旋转': 'Auto-rotate restored',
    '此设备不支持画中画（需 Android 8.0+）':
        'Picture-in-Picture not supported on this device (requires Android 8.0+)',
    '画中画不可用': 'Picture-in-Picture unavailable',
    '画中画': 'Picture-in-Picture',
    '旋转屏幕': 'Rotate Screen',

    // ---------- 控制面板 ----------
    '控制面板': 'Control Panel',
    '面板样式': 'Panel Style',
    '关闭': 'Close',
    '同时加载数量': 'Concurrent Count',
    '列布局': 'Columns',
    '行布局': 'Rows',
    '预加载下一页': 'Preload Next Page',
    '码流': 'Quality',
    '分组': 'Group',
    '翻页': 'Page',
    '上一页': 'Prev Page',
    '下一页': 'Next Page',
    '左侧': 'Left',
    '底部': 'Bottom',
    'TV 模式': 'TV Mode',
    '开启': 'On',
    '播放器参数（调完翻页生效，自动保存）':
        'Player Parameters (apply after paging, auto-saved)',
    '解码方式': 'Decoder',
    '硬解': 'Hardware',
    '软解': 'Software',
    '硬解=GPU解码快，软解=CPU解码稳，自动=两者切换':
        'Hardware = fast GPU decode, Software = stable CPU decode, Auto = switch between them',
    '探测大小': 'Probe Size',
    '探测大小=识别流格式的缓存，越小越快但可能不稳定':
        'Probe size = cache for detecting stream format. Smaller = faster but less stable.',
    '分析时长': 'Analyze Duration',
    '分析时长=解码分析流的时间，越小越快但可能丢帧':
        'Analyze duration = time to analyze the stream. Smaller = faster but may drop frames.',
    '低延迟': 'Low Latency',
    'nobuffer=不缓冲直接播放，flush=清缓冲降延迟':
        'nobuffer = play without buffering, flush = clear buffer for lower latency',
    '首帧超时（秒）': 'First Frame Timeout (s)',
    '首帧最大等待时间，超时重连':
        'Max wait for the first frame; reconnect on timeout',
    '心跳超时（秒）': 'Heartbeat Timeout (s)',
    '出首帧后无新帧判定僵死': 'No new frame after the first frame = stream stuck',
    '缓冲秒数': 'Buffer Seconds',
    '缓冲多少秒再播放，0=不缓冲':
        'Seconds to buffer before playing; 0 = no buffer',
    '重连最大间隔（秒）': 'Max Reconnect Interval (s)',
    '网络断开后自动重连的最大等待时间':
        'Max wait before reconnecting after a network drop',
    '屏幕方向': 'Screen Orientation',
    '竖屏': 'Portrait',
    '横屏': 'Landscape',
    '操作说明': 'Help',
    '重置所有参数': 'Reset All',
    '界面语言': 'Language',
    '跟随系统': 'System',

    // ---------- 操作说明 ----------
    'M3U播放器 · 操作说明': 'M3U Player · Help',
    '基本操作': 'Basic Operations',
    '【打开 / 关闭控制面板】': '[Open / Close Control Panel]',
    '手机：点击屏幕中间区域，或点击顶部按钮':
        'Phone: tap the center of the screen, or tap the top button',
    '电视：按遥控器菜单键 MENU': 'TV: press the MENU key on the remote',
    '【翻页】': '[Change Page]',
    '手机：网格模式下，手指上滑=下一页，下滑=上一页':
        'Phone: in grid mode, swipe up = next page, swipe down = previous page',
    '电视：按左右方向键，或用控制面板的翻页按钮':
        'TV: press left/right arrow keys, or use the page buttons in the control panel',
    '【切换分组】': '[Switch Group]',
    '手机：底部半透明条左右滑动选择分组':
        'Phone: swipe the semi-transparent bar at the bottom to select a group',
    '电视：控制面板里选择分组': 'TV: select a group in the control panel',
    '【切换码流】': '[Switch Quality]',
    '控制面板里选择：清晰 / 流畅':
        'Select in the control panel: 清晰 (HD) / 流畅 (Lite)',
    '【切换布局】': '[Change Layout]',
    '控制面板里用加减按钮调节：同时加载数量（1~16路）':
        'Use +/- buttons in the control panel: concurrent count (1~16)',
    '还可以用加减按钮调节：列布局、行布局（1~4列/行）':
        'You can also adjust columns / rows (1~4 each) with +/- buttons',
    '电脑版（Windows / Linux）': 'Desktop (Windows / Linux)',
    '【进入全屏】': '[Enter Fullscreen]',
    '双击某个视频画面': 'Double-click a video tile',
    '【退出全屏】': '[Exit Fullscreen]',
    '按 ESC 键，或点击鼠标右键': 'Press ESC, or right-click',
    '鼠标滚轮向下滚 = 下一页，向上滚 = 上一页':
        'Scroll wheel down = next page, scroll wheel up = previous page',
    '列表可滚动时：滚到底部继续下滚 = 下一页，滚到顶部继续上滚 = 上一页':
        'When the list scrolls: scroll past the bottom = next page, scroll past the top = previous page',
    '【加载播放列表】': '[Load Playlist]',
    '直接把 M3U 文件拖进窗口即可': 'Drag and drop an M3U file into the window',
    '也可以打开控制面板点击"加载 M3U 文件"':
        'Or open the control panel and tap "Load M3U File"',
    '【键盘】': '[Keyboard]',
    '方向键移动选中，Enter / 空格进入全屏':
        'Arrow keys move focus, Enter / Space enters fullscreen',
    '【配置保存】': '[Settings Saving]',
    '所有修改自动保存到软件目录下的 config.ini，下次启动恢复':
        'All changes are auto-saved to config.ini in the app folder and restored on next launch',
    '全屏模式': 'Fullscreen Mode',
    '手机：双击某个视频画面': 'Phone: double-tap a video tile',
    '电视：方向键选中后按 OK 键': 'TV: select with arrow keys and press OK',
    '手机：再双击一次，或按系统返回键':
        'Phone: double-tap again, or press the system back key',
    '电视：按返回键': 'TV: press the back key',
    '【全屏内缩放】': '[Zoom in Fullscreen]',
    '手机：双指捏合放大缩小，最大 8 倍':
        'Phone: pinch to zoom, up to 8x',
    '电视：暂不支持缩放': 'TV: zoom not supported',
    '【全屏内旋转】': '[Rotate in Fullscreen]',
    '手机：双击全屏画面，在横屏 / 竖屏之间切换':
        'Phone: double-tap the fullscreen picture to switch between landscape / portrait',
    '【全屏声音】': '[Fullscreen Sound]',
    '进入全屏后自动打开声音，退出后静音':
        'Sound turns on when entering fullscreen and mutes when exiting',
    '返回键行为': 'Back Key Behavior',
    '【按一次返回键】': '[Press back once]',
    '如果控制面板打开：关闭控制面板':
        'If the control panel is open: close the control panel',
    '如果在全屏模式：退出全屏': 'If in fullscreen: exit fullscreen',
    '如果在主界面：提示再按一次退出':
        'If on the main screen: hint to press back again to exit',
    '【快速按两次返回键】': '[Press back twice quickly]',
    '在主界面快速按两次，直接退出软件':
        'On the main screen, press back twice quickly to exit the app',
    '电视遥控器': 'TV Remote',
    '方向键：移动选中焦点': 'Arrow keys: move the selection focus',
    'OK / 确认键：进入选中的画面': 'OK / Enter: open the selected tile',
    '菜单键 MENU：打开 / 关闭控制面板':
        'MENU key: open / close the control panel',
    '返回键：关闭面板 · 退出全屏 · 退出软件':
        'Back key: close panel · exit fullscreen · exit app',
    '画面提示': 'On-Screen Hints',
    '顶部信息条 3 秒自动隐藏，轻触唤出':
        'Top info bar auto-hides after 3 seconds; tap to show',
    '底部半透明条为分组，左右滑动切换':
        'The semi-transparent bar at the bottom is the group bar; swipe left/right to switch',
    '控制面板：布局 / 码流 / 预加载 / 翻页 / 参数设置':
        'Control panel: layout / quality / preload / page / parameter settings',
    '所有修改的设置会自动保存，下次打开生效':
        'All settings are saved automatically and take effect on next launch',
    '点重置所有参数可以恢复默认设置':
        'Tap "Reset All" to restore default settings',
    'M3U 分组 / 码流设置': 'M3U Group / Quality Setup',
    '分组 = group-title 的值，如 group-title="教室1;清晰"':
        'Group = the value of group-title, e.g. group-title="教室1;清晰"',
    '分号 ; 后面的就是码流名（清晰 / 流畅，可自定义）':
        'The part after the semicolon is the quality name (清晰 / 流畅, customizable)',
    'URL 结尾 _0 = 清晰(HEVC)、_1 = 流畅(H.264)':
        'URL ending _0 = 清晰 (HEVC), _1 = 流畅 (H.264)',
    '一个频道只识别第一个 group-title':
        'Only the first group-title of a channel is used',
    '没有分组标记的频道归入"全部"':
        'Channels without a group marker go into "全部" (All)',
    '播放器参数（调完翻页生效）': 'Player Parameters (apply after paging)',
    '【解码方式】': '[Decoder]',
    '自动：自动选择硬解或软解，推荐默认':
        'Auto: automatically choose hardware or software decode (recommended)',
    '硬解：GPU硬件解码，占用CPU低，播放流畅':
        'Hardware: GPU decode, low CPU usage, smooth playback',
    '软解：CPU软件解码，兼容性好，占用CPU高':
        'Software: CPU decode, better compatibility, higher CPU usage',
    '如果硬解黑屏或卡顿，切到软试试':
        'If hardware decode shows a black screen or stutters, try software',
    '【探测大小】avformat.probesize': '[Probe Size] avformat.probesize',
    '识别流格式的缓存大小，单位字节':
        'Cache size for detecting the stream format, in bytes',
    '越小：首帧出得快，但可能识别不全导致失败':
        'Smaller: faster first frame, but may fail to detect the format',
    '越大：识别准确，但首帧出得慢':
        'Larger: accurate detection, but slower first frame',
    '推荐：32K（32768），网络好可以 8K':
        'Recommended: 32K (32768); 8K if the network is good',
    '【分析时长】avformat.analyzeduration':
        '[Analyze Duration] avformat.analyzeduration',
    '解码分析流信息的时间，单位微秒':
        'Time to analyze the stream, in microseconds',
    '越小：首帧出得快，但可能丢帧或卡顿':
        'Smaller: faster first frame, but may drop frames or stutter',
    '越大：分析充分，播放稳定，但首帧慢':
        'Larger: thorough analysis, stable playback, but slower first frame',
    '推荐：20ms（20000微秒）': 'Recommended: 20ms (20000 microseconds)',
    '【低延迟 nobuffer】avformat.fflags=+nobuffer':
        '[Low Latency] avformat.fflags=+nobuffer',
    'FFmpeg 低延迟开关，不缓冲直接播放':
        'FFmpeg low-latency switch: play without buffering',
    '开启：延迟低，但网络抖动时容易卡顿':
        'On: lower latency, but may stutter on network jitter',
    '关闭：有缓冲，播放更平滑，延迟高一点':
        'Off: buffered, smoother playback, slightly higher latency',
    '监控场景推荐：开启': 'Recommended for surveillance: On',
    '清缓冲降延迟，每次出包立即播放':
        'Flush the buffer to lower latency; play each packet immediately',
    '和 nobuffer 配合使用，进一步降低延迟':
        'Use together with nobuffer to further reduce latency',
    '【首帧超时】': '[First Frame Timeout]',
    '打开流后，多少秒没出首帧就判定失败，自动重连':
        'If no first frame appears within this many seconds, it fails and reconnects',
    '推荐：3秒，网络差可以调到 5~10 秒':
        'Recommended: 3s; 5~10s on a poor network',
    '【心跳超时】': '[Heartbeat Timeout]',
    '出首帧后，多少秒没新帧就判定僵死，自动重连':
        'After the first frame, if no new frame appears within this many seconds, it is considered stuck and reconnects',
    '推荐：5秒，监控流稳定，5秒没新帧说明断了':
        'Recommended: 5s. If a surveillance stream shows no new frame for 5s, it is disconnected',
    '【缓冲秒数】setBufferRange': '[Buffer Seconds] setBufferRange',
    'fvp 播放器缓冲机制，缓冲多少秒再播放':
        'fvp buffering: how many seconds to buffer before playing',
    '0：不缓冲，低延迟，和 nobuffer 配合':
        '0: no buffering, low latency, pair with nobuffer',
    '2~5秒：缓冲几秒，播放更稳定，延迟高':
        '2~5s: buffer a few seconds, more stable, higher latency',
    '注意：不要和 nobuffer 同时开': 'Note: do not enable both with nobuffer',
    '  低延迟方案：nobuffer=开，缓冲秒数=0':
        '  Low-latency setup: nobuffer=On, buffer=0',
    '  稳定优先方案：nobuffer=关，缓冲秒数=2~5':
        '  Stability-first setup: nobuffer=Off, buffer=2~5',
    '【重连最大间隔】avio.reconnect_delay_max':
        '[Max Reconnect Interval] avio.reconnect_delay_max',
    '网络断开后，自动重连的最大等待时间':
        'Max wait time before auto-reconnecting after the network drops',
    '推荐：7秒，不要太小，避免频繁重连':
        'Recommended: 7s. Do not set it too small to avoid frequent reconnects',
  };
}
