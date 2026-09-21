import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:fvp/mdk.dart' as mdk;
import 'package:fvp/fvp.dart' as fvp_reg;

/// 播放器参数配置（控制面板可调）
class PlayerConfig {
  final String videoDecoder; // auto / mediacodec / software
  final int probesize;
  final int analyzeduration; // 微秒
  final bool nobuffer;
  final bool flushPackets;
  final int reconnectDelayMax;
  final int bufferSeconds;

  const PlayerConfig({
    this.videoDecoder = 'mediacodec',
    this.probesize = 32768,
    this.analyzeduration = 20000,
    this.nobuffer = true,
    this.flushPackets = true,
    this.reconnectDelayMax = 7,
    this.bufferSeconds = 0,
  });

  PlayerConfig copyWith({
    String? videoDecoder,
    int? probesize,
    int? analyzeduration,
    bool? nobuffer,
    bool? flushPackets,
    int? reconnectDelayMax,
    int? bufferSeconds,
  }) =>
      PlayerConfig(
        videoDecoder: videoDecoder ?? this.videoDecoder,
        probesize: probesize ?? this.probesize,
        analyzeduration: analyzeduration ?? this.analyzeduration,
        nobuffer: nobuffer ?? this.nobuffer,
        flushPackets: flushPackets ?? this.flushPackets,
        reconnectDelayMax: reconnectDelayMax ?? this.reconnectDelayMax,
        bufferSeconds: bufferSeconds ?? this.bufferSeconds,
      );
}

/// fvp 0.38.x 版 NativePlayerController——直接使用 mdk.Player。
class NativePlayerController {
  mdk.Player? _player;
  final Uri uri;
  final PlayerConfig config;
  bool _initialized = false;
  bool _hasFrame = false;
  bool _hasError = false;
  double _aspectRatio = 16 / 9;
  bool _looping = false;
  double _volume = 1.0;
  bool _disposed = false;

  final _listeners = <VoidCallback>[];
  StreamSubscription? _stateSub;
  StreamSubscription? _statusSub;
  StreamSubscription? _eventSub;

  NativePlayerController._(this.uri, this.config);

  factory NativePlayerController.networkUrl(Uri uri, {PlayerConfig? config}) {
    return NativePlayerController._(uri, config ?? const PlayerConfig());
  }

  _NativePlayerValue get value => _NativePlayerValue(
        isInitialized: _initialized,
        hasFrame: _hasFrame,
        hasError: _hasError,
        aspectRatio: _aspectRatio,
      );

  void addListener(VoidCallback listener) => _listeners.add(listener);
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void _notify() {
    if (_disposed) return;
    for (final l in _listeners) {
      try {
        l();
      } catch (_) {}
    }
  }

  Future<void> initialize() async {
    try {
      fvp_reg.registerWith();
      final player = mdk.Player();
      _player = player;

      // 播放状态
      _stateSub = player.onStateChanged.listen((e) {
        if (e.newValue == mdk.PlaybackState.playing ||
            e.newValue == mdk.PlaybackState.paused) {
          // 播放状态就绪即认为有帧（prepare 已解码首帧）
          if (!_hasFrame) {
            _hasFrame = true;
            _notify();
          }
        }
      });

      // 媒体状态（错误/缓冲）
      _statusSub = player.onMediaStatus.listen((e) {
        if (e.newValue.test(mdk.MediaStatus.invalid)) {
          _hasError = true;
          _notify();
        }
      });

      // 错误事件（category 为 error 时才是真错误；buffering 的 error 字段是进度值）
      _eventSub = player.onEvent.listen((ev) {
        if (ev.category == 'error' || ev.category.startsWith('error.')) {
          _hasError = true;
          _notify();
        }
      });

      // 网络容错/重连参数（从配置读取，控制面板可调）
      player.setProperty('video.decoder', config.videoDecoder);
      player.setProperty('avformat.strict', 'experimental');
      player.setProperty('avformat.safe', '0');
      player.setProperty('avio.reconnect', '1');
      player.setProperty('avio.reconnect_delay', '1');
      player.setProperty('avio.reconnect_delay_max', '${config.reconnectDelayMax}');
      player.setProperty('avformat.rtsp_transport', 'tcp');
      player.setProperty('avformat.extension_picky', '0');
      player.setProperty('avformat.allowed_segment_extensions', 'ALL');
      // 低延迟直播（从配置读取）
      final fflagsParts = <String>['genpts'];
      if (config.nobuffer) fflagsParts.add('nobuffer');
      if (config.flushPackets) fflagsParts.add('flush_packets');
      player.setProperty('avformat.fflags', '+${fflagsParts.join('+')}');
      player.setProperty('avformat.fpsprobesize', '0');
      player.setProperty('avformat.probesize', '${config.probesize}');
      player.setProperty('avformat.analyzeduration', '${config.analyzeduration}');
      player.setProperty('avformat.allowed_media_types', 'video,audio');
      player.setBufferRange(min: 0, max: Duration(seconds: config.bufferSeconds).inMilliseconds);

      // 设置媒体源
      player.media = uri.toString();

      // 必须 prepare：加载并解码首帧
      final ret = await player.prepare();
      if (ret < 0) {
        _hasError = true;
        _notify();
        return;
      }

      // 等视频尺寸
      final size = await player.textureSize;
      if (size != null && size.width > 0 && size.height > 0) {
        _aspectRatio = size.width / size.height;
      }

      // 必须创建纹理，否则 textureId 为 null，画面不显示
      await player.updateTexture();

      _initialized = true;
      // prepare 已解码首帧，texture 已创建，立即设置有帧
      _hasFrame = true;
      _notify();
    } catch (e) {
      _hasError = true;
      _notify();
    }
  }

  void play() {
    final p = _player;
    if (p == null) return;
    p.state = mdk.PlaybackState.playing;
    if (_looping) p.loop = -1;
    p.volume = _volume;
  }

  void setLooping(bool v) {
    _looping = v;
    _player?.loop = v ? -1 : 0;
  }

  void setVolume(double v) {
    _volume = v;
    _player?.volume = v;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // 1) 取消所有 Dart 侧监听
    _stateSub?.cancel();
    _statusSub?.cancel();
    _eventSub?.cancel();
    _stateSub = null;
    _statusSub = null;
    _eventSub = null;
    // 2) 先停播
    try {
      _player?.state = mdk.PlaybackState.stopped;
    } catch (_) {}
    // 3) 立即释放对 player 的引用（NativeVideoPlayer 的 ValueListenableBuilder
    //    在下一帧 build 时会看到 _disposed=true，立即停止渲染 Texture，避免 Surface 竞争）
    final p = _player;
    _player = null;
    _listeners.clear();
    // 4) 延迟真正 dispose native player，给 native 事件循环让出时间跑完挂起回调，
    //    避免 ValueListenableBuilder 仍监听已 dispose textureId 触发段错误闪退
    if (p != null) {
      Future.delayed(const Duration(milliseconds: 800), () {
        try {
          p.dispose();
        } catch (_) {}
      });
    }
  }
}

class _NativePlayerValue {
  final bool isInitialized;
  final bool hasFrame;
  final bool hasError;
  final double aspectRatio;
  const _NativePlayerValue({
    required this.isInitialized,
    required this.hasFrame,
    required this.hasError,
    required this.aspectRatio,
  });
}

/// fvp 播放 widget——监听 textureId，纹理创建后显示
class NativeVideoPlayer extends StatelessWidget {
  final NativePlayerController controller;
  const NativeVideoPlayer({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    // 已 dispose 的 controller 直接返回空，避免监听已释放 player 的 textureId 触发 native 段错误
    if (controller._disposed) return const SizedBox.expand();
    final p = controller._player;
    if (p == null) return const SizedBox.expand();
    return ValueListenableBuilder<int?>(
      valueListenable: p.textureId,
      builder: (context, textureId, child) {
        // dispose 后 textureId 可能变成 null 或无效，直接返回空
        if (controller._disposed || textureId == null || textureId < 0) {
          return const SizedBox.expand();
        }
        return Texture(textureId: textureId);
      },
    );
  }
}
