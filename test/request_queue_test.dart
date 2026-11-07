import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiori/core/models.dart';
import 'package:shiori/core/pixiv_client.dart';

http.Response body(String id) => http.Response(
  jsonEncode({
    'error': false,
    'body': {'title': id, 'userName': 'synthetic', 'content': 'text $id'},
  }),
  200,
);

Work series(int count) => Work(
  title: 'synthetic',
  author: 'test',
  link: const WorkLink(WorkKind.series, '1'),
  chapters: List.generate(
    count,
    (i) => Chapter(id: '${i + 1}', title: '', order: i + 1),
  ),
);

void main() {
  test(
    'parallel requests stay bounded and out-of-order responses keep catalog order',
    () async {
      var active = 0, peak = 0;
      final api = PixivClient(
        MockClient((request) async {
          final id = request.url.pathSegments.last;
          active++;
          if (active > peak) peak = active;
          await Future<void>.delayed(
            Duration(milliseconds: id == '1' ? 40 : 10),
          );
          active--;
          return body(id);
        }),
        pause: Duration.zero,
      );
      addTearDown(api.dispose);
      final progress = <int>[];
      final result = await api.extract(
        series(8),
        {'8', '7', '6', '5', '4', '3', '2', '1'},
        cancel: Cancellation(),
        onProgress: (done, _) => progress.add(done),
      );
      expect(peak, 3);
      expect(result.map((n) => n.id), List.generate(8, (i) => '${i + 1}'));
      expect(progress, List.generate(9, (i) => i));
    },
  );

  test(
    'minimum network start interval applies to concurrent callers',
    () async {
      final clock = Stopwatch()..start();
      final starts = <int>[];
      final api = PixivClient(
        MockClient((request) async {
          starts.add(clock.elapsedMilliseconds);
          await Future<void>.delayed(const Duration(milliseconds: 80));
          return body(request.url.pathSegments.last);
        }),
        pause: const Duration(milliseconds: 30),
      );
      addTearDown(api.dispose);
      await Future.wait(List.generate(6, (i) => api.novel('${i + 1}')));
      for (var i = 1; i < starts.length; i++) {
        expect(starts[i] - starts[i - 1], greaterThanOrEqualTo(25));
      }
    },
  );

  test(
    'concurrent readers share one request and cancelling one keeps the other',
    () async {
      var requests = 0;
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final api = PixivClient(
        MockClient((_) {
          requests++;
          started.complete();
          return response.future;
        }),
        pause: Duration.zero,
      );
      addTearDown(api.dispose);
      final cancel = Cancellation();
      final first = api.novel('1', cancel: cancel);
      final second = api.novel('1');
      final cancelled = expectLater(first, throwsA(isA<Cancelled>()));
      await started.future;
      cancel.cancel();
      await cancelled;
      response.complete(body('1'));
      expect((await second).id, '1');
      expect(requests, 1);
    },
  );

  test(
    'cache hits skip network pacing, LRU is bounded, and TTL expires',
    () async {
      var now = DateTime.utc(2026);
      var requests = 0;
      final api = PixivClient(
        MockClient((request) async {
          requests++;
          return body(request.url.pathSegments.last);
        }),
        pause: Duration.zero,
        maxCacheEntries: 2,
        now: () => now,
      );
      addTearDown(api.dispose);
      await api.novel('1');
      await api.novel('2');
      await api.novel('1'); // Make 2 least recently used.
      await api.novel('3');
      await api.novel('1');
      expect(requests, 3);
      await api.novel('2');
      expect(requests, 4);
      now = now.add(const Duration(minutes: 11));
      await api.novel('2');
      expect(requests, 5);
    },
  );

  test('cache character budget evicts large content', () async {
    var requests = 0;
    final api = PixivClient(
      MockClient((request) async {
        requests++;
        return body(request.url.pathSegments.last);
      }),
      pause: Duration.zero,
      maxCacheCharacters: 6,
    );
    addTearDown(api.dispose);
    await api.novel('1');
    await api.novel('2');
    await api.novel('1');
    expect(requests, 3);
  });

  test(
    'changing session aborts pending reads and cannot repopulate old cache',
    () async {
      var requests = 0;
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final api = PixivClient(
        MockClient((request) {
          requests++;
          if (requests == 1) {
            started.complete();
            return response.future;
          }
          expect(request.headers['Cookie'], 'PHPSESSID=new_session_1234');
          return Future.value(body('new'));
        }),
        pause: Duration.zero,
      );
      addTearDown(api.dispose);
      api.setSession('old_session_1234');
      final old = expectLater(api.novel('1'), throwsA(isA<Cancelled>()));
      await started.future;
      api.setSession('new_session_1234');
      response.complete(body('old'));
      await old;
      expect((await api.novel('1')).title, 'new');
      expect((await api.novel('1')).title, 'new');
      expect(requests, 2);
    },
  );

  test(
    'first failed chapter aborts its peers and never starts the remaining batch',
    () async {
      final requests = <String>[];
      final api = PixivClient(
        MockClient((request) async {
          final id = request.url.pathSegments.last;
          requests.add(id);
          if (id == '2') return http.Response('', 404);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return body(id);
        }),
        pause: Duration.zero,
      );
      addTearDown(api.dispose);
      await expectLater(
        api.extract(series(10), {
          for (var i = 1; i <= 10; i++) '$i',
        }, cancel: Cancellation()),
        throwsA(isA<PixivException>()),
      );
      expect(requests.length, lessThanOrEqualTo(3));
      expect(requests, contains('2'));
    },
  );

  test(
    '429 Retry-After pauses all queued starts, not only the failed request',
    () async {
      final clock = Stopwatch()..start();
      final starts = <int>[];
      var requests = 0;
      final api = PixivClient(
        MockClient((request) async {
          starts.add(clock.elapsedMilliseconds);
          if (++requests == 1) {
            return http.Response('', 429, headers: {'retry-after': '1'});
          }
          return body(request.url.pathSegments.last);
        }),
        pause: const Duration(milliseconds: 20),
      );
      addTearDown(api.dispose);
      await Future.wait([api.novel('1'), api.novel('2'), api.novel('3')]);
      expect(requests, 4);
      expect(starts.skip(1), everyElement(greaterThanOrEqualTo(900)));
    },
  );

  test(
    'long HTTP-date Retry-After is not shortened into aggressive retries',
    () async {
      var requests = 0;
      final api = PixivClient(
        MockClient((_) async {
          requests++;
          return http.Response(
            '',
            429,
            headers: {'retry-after': 'Thu, 01 Jan 2026 00:02:00 GMT'},
          );
        }),
        pause: Duration.zero,
        now: () => DateTime.utc(2026),
      );
      addTearDown(api.dispose);
      await expectLater(api.novel('1'), throwsA(isA<PixivException>()));
      expect(requests, 1);
    },
  );

  test(
    'cancellation during cooldown returns promptly without a retry',
    () async {
      final limited = Completer<void>();
      var requests = 0;
      final api = PixivClient(
        MockClient((_) async {
          requests++;
          limited.complete();
          return http.Response('', 429, headers: {'retry-after': '30'});
        }),
        pause: Duration.zero,
      );
      addTearDown(api.dispose);
      final cancel = Cancellation();
      final result = expectLater(
        api.novel('1', cancel: cancel),
        throwsA(isA<Cancelled>()),
      );
      await limited.future;
      cancel.cancel();
      await result.timeout(const Duration(seconds: 1));
      expect(requests, 1);
    },
  );
}
