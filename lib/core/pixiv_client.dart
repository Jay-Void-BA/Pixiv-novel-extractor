import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'models.dart';

class PixivClient {
  PixivClient(
    this.httpClient, {
    this.pause = const Duration(milliseconds: 700),
  });
  final http.Client httpClient;
  final Duration pause;
  final Map<String, Novel> _cache = {};
  String? _session;

  void setSession(String? value) {
    if (value != null && !RegExp(r'^[A-Za-z0-9_%.-]{8,512}$').hasMatch(value)) {
      throw const FormatException('PHPSESSID 格式无效。只需粘贴该 Cookie 的值。');
    }
    _session = value;
    _cache.clear();
  }

  Future<dynamic> _get(String path, {Cancellation? cancel}) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      cancel?.check();
      http.Response response;
      try {
        response = await httpClient
            .get(
              Uri.parse('https://www.pixiv.net$path'),
              headers: {
                'Accept': 'application/json',
                'Referer': 'https://www.pixiv.net/',
                'User-Agent': 'Mozilla/5.0 Shiori/1.0',
                if (_session != null) 'Cookie': 'PHPSESSID=$_session',
              },
            )
            .timeout(const Duration(seconds: 25));
      } on TimeoutException {
        if (attempt < 2) {
          await _backoff(attempt, cancel);
          continue;
        }
        throw const PixivException('连接 Pixiv 超时，请检查网络后重试。');
      } on http.ClientException {
        throw const PixivException('无法连接 Pixiv，请检查网络或本地服务。');
      }
      cancel?.check();
      final status = response.statusCode;
      if (status == 401) throw const LoginRequired();
      if (status == 403) {
        if (_session == null) throw const LoginRequired();
        throw const PixivException(
          'Pixiv 拒绝访问（403）。会话可能已失效，也可能触发了访问限制；请重新登录或稍后重试。',
        );
      }
      if (status == 404) throw const PixivException('作品不存在、已删除，或当前账号没有访问权限。');
      if (status == 429 || status >= 500) {
        if (attempt < 2) {
          final retry = int.tryParse(response.headers['retry-after'] ?? '');
          await Future<void>.delayed(
            Duration(seconds: retry?.clamp(1, 15) ?? (2 << attempt)),
          );
          cancel?.check();
          continue;
        }
        throw PixivException(
          status == 429 ? 'Pixiv 请求过于频繁，请稍后再试。' : 'Pixiv 服务暂时不可用，请稍后再试。',
        );
      }
      if (status != 200) throw PixivException('Pixiv 请求失败（HTTP $status）。');
      dynamic data;
      try {
        data = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        throw const PixivException('Pixiv 返回了非 JSON 页面，可能需要浏览器验证或接口已变化。');
      }
      if (data is! Map<String, dynamic>) {
        throw const PixivException('Pixiv 响应格式发生变化。');
      }
      if (data['error'] == true) {
        final message = data['message']?.toString() ?? '';
        if (RegExp(
          r'login|log in|ログイン|登录|登入',
          caseSensitive: false,
        ).hasMatch(message)) {
          throw const LoginRequired();
        }
        throw const PixivException('Pixiv 无法提供此作品。请确认作品存在且账号有权访问。');
      }
      return data['body'];
    }
    throw const PixivException('请求失败。');
  }

  Future<void> _backoff(int attempt, Cancellation? cancel) async {
    await Future<void>.delayed(Duration(seconds: 2 << attempt));
    cancel?.check();
  }

  Future<Novel> novel(String id, {Cancellation? cancel}) async {
    cancel?.check();
    if (_cache.containsKey(id)) return _cache[id]!;
    final body = await _get('/ajax/novel/$id', cancel: cancel);
    if (body is! Map<String, dynamic> || body['title'] is! String) {
      throw const PixivException('小说数据格式不受支持。');
    }
    final content = body['content'];
    if (content is! String || content.trim().isEmpty) {
      if (_session == null) throw const LoginRequired();
      throw const PixivException('正文为空或当前账号没有阅读权限，已停止导出。');
    }
    final nav = body['seriesNavData'];
    final result = Novel(
      id: id,
      title: body['title'] as String,
      author: body['userName']?.toString() ?? '未知作者',
      content: content,
      description: body['description']?.toString() ?? '',
      seriesId: nav is Map ? nav['seriesId']?.toString() : null,
    );
    _cache[id] = result;
    return result;
  }

  Future<Work> load(WorkLink link, {Cancellation? cancel}) async {
    if (link.kind == WorkKind.novel) {
      final n = await novel(link.id, cancel: cancel);
      return Work(
        title: n.title,
        author: n.author,
        description: n.description,
        link: link,
        chapters: [
          Chapter(
            id: n.id,
            title: n.title,
            order: 1,
            characterCount: n.content.runes.length,
          ),
        ],
      );
    }
    final data = await _get('/ajax/novel/series/${link.id}', cancel: cancel);
    if (data is! Map<String, dynamic> || data['title'] is! String) {
      throw const PixivException('系列数据格式不受支持。');
    }
    // content_titles returns the entire ordered title list (not a paginated feed).
    // Do not confuse it with /series_content/:id, which is paginated.
    final titles = await _get(
      '/ajax/novel/series/${link.id}/content_titles',
      cancel: cancel,
    );
    if (titles is! List) throw const PixivException('系列目录格式不受支持。');
    final chapters = <Chapter>[];
    final ids = <String>{};
    for (final item in titles) {
      if (item is! Map || item['id'] == null || item['title'] == null) {
        throw const PixivException('系列目录不完整，已停止加载。');
      }
      final id = item['id'].toString();
      if (!RegExp(r'^[1-9]\d*$').hasMatch(id) || !ids.add(id)) {
        throw const PixivException('系列目录包含无效或重复的小说 ID。');
      }
      chapters.add(
        Chapter(
          id: id,
          title: item['title'].toString(),
          order: chapters.length + 1,
          available: item['available'] != false,
          characterCount: int.tryParse('${item['textCount']}') ?? 0,
        ),
      );
    }
    if (chapters.isEmpty) throw const PixivException('该系列没有可提取的章节。');
    final total = int.tryParse('${data['total']}');
    if (total != null && total != chapters.length) {
      throw const PixivException(
        '系列目录数量与总数不一致，可能有无权查看的章节或接口发生变化。已停止，避免生成不完整文件。',
      );
    }
    return Work(
      title: data['title'] as String,
      author: data['userName']?.toString() ?? '未知作者',
      description: data['caption']?.toString() ?? '',
      link: link,
      chapters: chapters,
    );
  }

  Future<List<Novel>> extract(
    Work work,
    Set<String> selected, {
    required Cancellation cancel,
    void Function(int done, int total)? onProgress,
  }) async {
    final chapters = work.chapters
        .where((c) => selected.contains(c.id))
        .toList();
    if (chapters.isEmpty) throw const PixivException('请先选择至少一个章节。');
    if (chapters.any((c) => !c.available)) {
      throw const PixivException('所选章节中包含不可访问的作品。');
    }
    final result = <Novel>[];
    onProgress?.call(0, chapters.length);
    for (final c in chapters) {
      cancel.check();
      if (result.isNotEmpty) await Future<void>.delayed(pause);
      result.add(await novel(c.id, cancel: cancel));
      onProgress?.call(result.length, chapters.length);
    }
    cancel.check();
    return result;
  }

  void dispose() {
    _cache.clear();
    _session = null;
    httpClient.close();
  }
}
