enum WorkKind { novel, series }

class WorkLink {
  const WorkLink(this.kind, this.id);
  final WorkKind kind;
  final String id;

  static WorkLink parse(String input) {
    final value = input.trim();
    if (RegExp(r'^[1-9]\d*$').hasMatch(value)) {
      return WorkLink(WorkKind.novel, value);
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        !{'www.pixiv.net', 'pixiv.net'}.contains(uri.host) ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443)) {
      throw const FormatException('请输入 Pixiv 小说链接、系列链接或小说 ID。');
    }
    final series = RegExp(
      r'^/(?:[a-z]{2}/)?novel/series/([1-9]\d*)/?$',
    ).firstMatch(uri.path);
    if (series != null) return WorkLink(WorkKind.series, series[1]!);
    if (RegExp(r'^/(?:[a-z]{2}/)?novel/show\.php$').hasMatch(uri.path)) {
      final id = uri.queryParameters['id'] ?? '';
      if (RegExp(r'^[1-9]\d*$').hasMatch(id)) {
        return WorkLink(WorkKind.novel, id);
      }
    }
    throw const FormatException('此链接不是 Pixiv 小说或小说系列。');
  }
}

class Chapter {
  const Chapter({
    required this.id,
    required this.title,
    required this.order,
    this.available = true,
    this.characterCount = 0,
  });
  final String id;
  final String title;
  final int order;
  final bool available;
  final int characterCount;
}

class Novel {
  const Novel({
    required this.id,
    required this.title,
    required this.author,
    required this.content,
    this.description = '',
    this.seriesId,
  });
  final String id;
  final String title;
  final String author;
  final String content;
  final String description;
  final String? seriesId;
  String get url => 'https://www.pixiv.net/novel/show.php?id=$id';
}

class Work {
  const Work({
    required this.title,
    required this.author,
    required this.chapters,
    required this.link,
    this.description = '',
  });
  final String title;
  final String author;
  final String description;
  final List<Chapter> chapters;
  final WorkLink link;
}

/// One-based positions, never novel IDs. Ranges are inclusive.
Set<String> parseSelection(String input, List<Chapter> chapters) {
  final indices = <int>{};
  if (input.trim().isEmpty) return {};
  for (final part in input.replaceAll('，', ',').split(',')) {
    final match = RegExp(r'^\s*(\d+)\s*(?:-\s*(\d+))?\s*$').firstMatch(part);
    if (match == null) throw const FormatException('范围格式示例：1-5, 8, 10-12');
    final start = int.parse(match[1]!);
    final end = int.parse(match[2] ?? match[1]!);
    if (start < 1 || end < start || end > chapters.length) {
      throw FormatException('章节范围必须在 1-${chapters.length} 内，起点不能大于终点。');
    }
    for (var i = start; i <= end; i++) {
      indices.add(i - 1);
    }
  }
  return {for (final i in indices) chapters[i].id};
}

class PixivException implements Exception {
  const PixivException(this.message);
  final String message;
  @override
  String toString() => message;
}

class LoginRequired extends PixivException {
  const LoginRequired() : super('此内容需要登录，或当前会话已过期。请登录 Pixiv 后重试。');
}

class Cancelled implements Exception {
  const Cancelled();
}

class Cancellation {
  bool _cancelled = false;
  void cancel() => _cancelled = true;
  void check() {
    if (_cancelled) throw const Cancelled();
  }
}
