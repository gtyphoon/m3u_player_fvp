/// M3U 播放列表解析器
/// group-title 格式支持分号拆分："教室1;清晰" → 分组=教室1，码流=清晰
library;

class Channel {
  final String name;
  final String group;
  final String quality;
  final String url;

  const Channel({
    required this.name,
    required this.group,
    required this.quality,
    required this.url,
  });
}

/// 解析 M3U 文本，返回频道列表
List<Channel> parseM3U(String content) {
  final channels = <Channel>[];
  final lines = content.split('\n');

  String? pendingName;
  String? pendingGroup;
  String? pendingQuality;

  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#EXTINF')) {
      var name = '';
      var group = '';
      var quality = '自动';

      final groupMatch = RegExp(r'group-title="([^"]*)"').firstMatch(line);
      if (groupMatch != null) {
        final gt = groupMatch.group(1)!;
        final parts = gt.split(';');
        group = parts.first.trim();
        if (parts.length > 1) {
          quality = parts.sublist(1).join(';').trim();
        }
      }
      final commaIdx = line.lastIndexOf(',');
      if (commaIdx >= 0) {
        name = line.substring(commaIdx + 1).trim();
      }
      pendingName = name;
      pendingGroup = group;
      pendingQuality = quality;
    } else if (line.startsWith('http://') ||
        line.startsWith('https://') ||
        line.startsWith('rtmp://') ||
        line.startsWith('rtsp://') ||
        line.startsWith('udp://')) {
      if (pendingName != null) {
        channels.add(Channel(
          name: pendingName.isEmpty ? line : pendingName,
          group: pendingGroup ?? '',
          quality: pendingQuality ?? '自动',
          url: line,
        ));
        pendingName = null;
      }
    }
  }
  return channels;
}
