import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'models.dart';

class _CachedNovel {
  _CachedNovel(this.novel, this.expires);
  final Novel novel;
  final DateTime expires;
  int get size => novel.content.length + novel.description.length;
}

class _PendingNovel {
  final cancel = Cancellation();
  late final Future<Novel> future;
  int readers = 0;
}

class PixivClient {
  PixivClient(
    this.httpClient, {
    this.pause = const Duration(milliseconds: 350),
    this.maxConcurrent = 3,
    this.maxCacheEntries = 128,
    this.maxCacheCharacters = 4000000,
    this.cacheLifetime = const Duration(minutes: 10),
    this.requestTimeout = const Duration(seconds: 25),
    this.retryBase = const Duration(seconds: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (maxConcurrent < 1 || maxConcurrent > 4 || pause.isNegative) {
      throw ArgumentError('Invalid request limits');
    }
  }

  final http.Client httpClient;
  /// Minimum interval between network starts, including retries and catalog calls.
  final Duration pause;
  final int maxConcurrent, maxCacheEntries, maxCacheCharacters;
  final Duration cacheLifetime, requestTimeout, retryBase;
  final DateTime Function() _now;
  final _cache = LinkedHashMap<String, _CachedNovel>();
  final _pending = <String, _PendingNovel>{};
  final _slots = Queue<Completer<void>>();
  int _active = 0, _cacheCharacters = 0;
  Future<void> _turn = Future<void>.value();
  DateTime? _nextStart, _cooldown;
  Cancellation _identity = Cancellation();
  String? _session;
  bool _disposed = false;

  void setSession(String? value) {
    if (value != null && !RegExp(r'^[A-Za-z0-9_%.-]{8,512}$').hasMatch(value)) {
      throw const FormatException('PHPSESSID 格式无效。只需粘贴该 Cookie 的值。');
    }
    _identity.cancel();
    _identity = Cancellation();
    _session = value;
    _clearCache();
    _pending.clear();
    // Keep the shared rate limit when changing accounts.
  }

  void _check(Cancellation cancel, Cancellation identity) {
    cancel.check();
    identity.check();
    if (_disposed) throw const Cancelled();
  }

  Future<T> _bound<T>(
    Future<T> task,
    Cancellation cancel,
    Cancellation identity,
  ) => cancel.bind(identity.bind(task));

  Future<void> _wait(
    Duration duration,
    Cancellation cancel,
    Cancellation identity,
  ) async {
    _check(cancel, identity);
    if (duration <= Duration.zero) return;
    final result = Completer<void>();
    final timer = Timer(duration, result.complete);
    try {
      await _bound(result.future, cancel, identity);
    } finally {
      timer.cancel();
    }
    _check(cancel, identity);
  }

  Future<void> _acquire(Cancellation cancel, Cancellation identity) async {
    _check(cancel, identity);
    if (_active < maxConcurrent) {
      _active++;
      return;
    }
    final ticket = Completer<void>();
    _slots.add(ticket);
    try {
      await _bound(ticket.future, cancel, identity);
    } catch (_) {
      if (!_slots.remove(ticket)) _release();
      rethrow;
    }
  }

  void _release() {
    if (_slots.isNotEmpty) {
      _slots.removeFirst().complete();
    } else {
      _active--;
    }
  }

  Future<void> _pace(Cancellation cancel, Cancellation identity) {
    final scheduled = _turn.then((_) async {
      while (true) {
        _check(cancel, identity);
        final now = _now();
        var start = _nextStart ?? now;
        if (_cooldown != null && _cooldown!.isAfter(start)) start = _cooldown!;
        final wait = start.difference(now);
        if (wait > const Duration(minutes: 1)) {
          throw const PixivException('Pixiv 要求较长的冷却时间，请稍后再试。');
        }
        if (wait <= Duration.zero) break;
        await _wait(wait, cancel, identity);
      }
      _nextStart = _now().add(pause);
    });
    _turn = scheduled.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return scheduled;
  }

  void _coolDown(Duration delay) {
    final until = _now().add(delay);
    if (_cooldown == null || until.isAfter(_cooldown!)) _cooldown = until;
  }

  Future<dynamic> _get(String path, {Cancellation? cancel}) async {
    final operation = cancel ?? Cancellation();
    final identity = _identity;
    final session = _session;
    for (var attempt = 0; attempt < 3; attempt++) {
      _check(operation, identity);
      await _acquire(operation, identity);
      http.Response response;
      try {
        await _bound(_pace(operation, identity), operation, identity);
        _check(operation, identity);
        final abort = Completer<void>();
        void stop() {
          if (!abort.isCompleted) abort.complete();
        }
        final removeCancel = operation.listen(stop);
        final removeIdentity = identity.listen(stop);
        try {
          final request = http.AbortableRequest(
            'GET',
            Uri.parse('https://www.pixiv.net$path'),
            abortTrigger: abort.future,
          )..headers.addAll({
              'Accept': 'application/json',
              'Referer': 'https://www.pixiv.net/',
              'User-Agent': 'Mozilla/5.0 Shiori/1.1',
              if (session != null) 'Cookie': 'PHPSESSID=$session',
            });
          final task = httpClient.send(request).then(http.Response.fromStream);
          response = await _bound(
            task.timeout(requestTimeout, onTimeout: () {
              stop();
              throw TimeoutException('Pixiv request timed out');
            }),
            operation,
            identity,
          );
        } finally {
          removeCancel();
          removeIdentity();
        }
      } on TimeoutException {
        if (attempt == 2) {
          throw const PixivException('连接 Pixiv 超时，请检查网络后重试。');
        }
        _coolDown(retryBase * (1 << attempt));
        continue;
      } on http.ClientException {
        _check(operation, identity);
        throw const PixivException('无法连接 Pixiv，请检查网络或本地服务。');
      } finally {
        _release();
      }
      _check(operation, identity);
      final status = response.statusCode;
      if (status == 401) throw const LoginRequired();
      if (status == 403) {
        if (session == null) throw const LoginRequired();
        throw const PixivException(
          'Pixiv 拒绝访问（403）。会话可能已失效，也可能触发了访问限制；请重新登录或稍后重试。',
        );
      }
      if (status == 404) throw const PixivException('作品不存在、已删除，或当前账号没有访问权限。');
      if (status == 429 || status >= 500) {
        _coolDown(
          _retryAfter(response.headers['retry-after']) ?? retryBase * (1 << attempt),
        );
        if (attempt < 2) continue;
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

  Duration? _retryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null && seconds >= 0) return Duration(seconds: seconds);
    // IMF-fixdate, the HTTP-date form of Retry-After; works on Web too.
    final match = RegExp(
      r'^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final month = months.indexOf(match[2]!);
    if (month < 0) return null;
    final date = DateTime.utc(int.parse(match[3]!), month + 1,
      int.parse(match[1]!), int.parse(match[4]!), int.parse(match[5]!),
      int.parse(match[6]!));
    final delay = date.difference(_now());
    return delay.isNegative ? Duration.zero : delay;
  }

  Future<Novel> novel(String id, {Cancellation? cancel}) async {
    cancel?.check();
    if (_disposed) throw const Cancelled();
    final cached = _cache.remove(id);
    if (cached != null) {
      if (cached.expires.isAfter(_now())) {
        _cache[id] = cached;
        return cached.novel;
      }
      _cacheCharacters -= cached.size;
    }
    var pending = _pending[id];
    if (pending == null) {
      pending = _PendingNovel();
      _pending[id] = pending;
      final entry = pending;
      final identity = _identity;
      entry.future = _fetchNovel(id, entry.cancel, identity).whenComplete(() {
        if (identical(_pending[id], entry)) _pending.remove(id);
      });
    }
    pending.readers++;
    try {
      return await (cancel == null ? pending.future : cancel.bind(pending.future));
    } finally {
      if (--pending.readers == 0) pending.cancel.cancel();
    }
  }

  Future<Novel> _fetchNovel(
    String id,
    Cancellation cancel,
    Cancellation identity,
  ) async {
    final body = await _get('/ajax/novel/$id', cancel: cancel);
    _check(cancel, identity);
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
    final cached = _CachedNovel(result, _now().add(cacheLifetime));
    if (maxCacheEntries > 0 && cached.size <= maxCacheCharacters) {
      _cache[id] = cached;
      _cacheCharacters += cached.size;
      while (_cache.length > maxCacheEntries ||
          _cacheCharacters > maxCacheCharacters) {
        _cacheCharacters -= _cache.remove(_cache.keys.first)!.size;
      }
    }
    return result;
  }

  Future<Work> load(WorkLink link, {Cancellation? cancel}) async {
    final identity = _identity;
    if (link.kind == WorkKind.novel) {
      final n = await novel(link.id, cancel: cancel);
      identity.check();
      return Work(
        title: n.title,
        author: n.author,
        description: n.description,
        link: link,
        chapters: [
          Chapter(id: n.id, title: n.title, order: 1,
            characterCount: n.content.runes.length),
        ],
      );
    }
    final group = Cancellation();
    final remove = cancel?.listen(group.cancel);
    late List<dynamic> catalog;
    try {
      catalog = await Future.wait([
        _get('/ajax/novel/series/${link.id}', cancel: group),
        // This endpoint returns the complete ordered catalog, not a 30-item feed.
        _get('/ajax/novel/series/${link.id}/content_titles', cancel: group),
      ], eagerError: true);
    } finally {
      group.cancel();
      remove?.call();
    }
    final data = catalog[0];
    final titles = catalog[1];
    identity.check();
    if (data is! Map<String, dynamic> || data['title'] is! String) {
      throw const PixivException('系列数据格式不受支持。');
    }
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
      chapters.add(Chapter(id: id, title: item['title'].toString(),
        order: chapters.length + 1, available: item['available'] != false,
        characterCount: int.tryParse('${item['textCount']}') ?? 0));
    }
    if (chapters.isEmpty) throw const PixivException('该系列没有可提取的章节。');
    final total = int.tryParse('${data['total']}');
    if (total != null && total != chapters.length) {
      throw const PixivException(
        '系列目录数量与总数不一致，可能有无权查看的章节或接口发生变化。已停止，避免生成不完整文件。',
      );
    }
    return Work(title: data['title'] as String,
      author: data['userName']?.toString() ?? '未知作者',
      description: data['caption']?.toString() ?? '', link: link, chapters: chapters);
  }

  Future<List<Novel>> extract(
    Work work,
    Set<String> selected, {
    required Cancellation cancel,
    void Function(int done, int total)? onProgress,
  }) async {
    cancel.check();
    final chapters = work.chapters.where((c) => selected.contains(c.id)).toList();
    if (chapters.isEmpty) throw const PixivException('请先选择至少一个章节。');
    if (chapters.any((c) => !c.available)) {
      throw const PixivException('所选章节中包含不可访问的作品。');
    }
    final batch = Cancellation();
    final remove = cancel.listen(batch.cancel);
    final removeIdentity = _identity.listen(batch.cancel);
    final result = List<Novel?>.filled(chapters.length, null);
    var next = 0, done = 0;
    Object? failure;
    StackTrace? failureStack;
    onProgress?.call(0, chapters.length);
    Future<void> worker() async {
      while (next < chapters.length) {
        final index = next++;
        try {
          batch.check();
          result[index] = await novel(chapters[index].id, cancel: batch);
          batch.check();
          onProgress?.call(++done, chapters.length);
        } catch (error, stack) {
          if (failure == null) {
            failure = error;
            failureStack = stack;
          }
          batch.cancel();
          return;
        }
      }
    }
    try {
      await Future.wait(List.generate(
        chapters.length < maxConcurrent ? chapters.length : maxConcurrent,
        (_) => worker(),
      ));
      if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
      cancel.check();
      return result.cast<Novel>();
    } finally {
      batch.cancel();
      remove();
      removeIdentity();
    }
  }

  void _clearCache() {
    _cache.clear();
    _cacheCharacters = 0;
  }

  void dispose() {
    _disposed = true;
    _identity.cancel();
    _clearCache();
    _pending.clear();
    _session = null;
    httpClient.close();
  }
}
