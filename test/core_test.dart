import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiori/core/models.dart';
import 'package:shiori/core/novel_text.dart';
import 'package:shiori/core/pixiv_client.dart';

http.Response ok(dynamic body) => http.Response(
  jsonEncode({'error': false, 'body': body}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
Map<String, dynamic> novelBody(String id) => {
  'id': id,
  'title': '章 $id',
  'userName': '测试作者',
  'content': '测试正文 $id',
};

void main() {
  group('work links', () {
    test('recognizes novel IDs, localized and series URLs', () {
      expect(WorkLink.parse(' 123 ').id, '123');
      expect(
        WorkLink.parse('https://www.pixiv.net/novel/show.php?id=234#x').id,
        '234',
      );
      expect(
        WorkLink.parse('https://pixiv.net/en/novel/series/456/?x=1').kind,
        WorkKind.series,
      );
    });
    test('rejects arbitrary hosts and non-novel links', () {
      for (final input in [
        '0',
        '-123',
        'https://www.pixiv.net.evil/novel/series/1',
        'http://www.pixiv.net/novel/series/1',
        'https://www.pixiv.net/artworks/1',
        'https://user@www.pixiv.net/novel/series/1',
        'https://www.pixiv.net/novel/show.php?id=0',
      ]) {
        expect(
          () => WorkLink.parse(input),
          throwsFormatException,
          reason: input,
        );
      }
    });
  });
  final chapters = List.generate(
    12,
    (i) => Chapter(id: '${100 + i}', title: '章', order: i + 1),
  );
  test('ranges are inclusive, deduplicated, and reject invalid bounds', () {
    expect(parseSelection('1-3， 3, 8, 10-12', chapters), {
      '100',
      '101',
      '102',
      '107',
      '109',
      '110',
      '111',
    });
    for (final input in ['0', '13', '5-2', '1-99', 'x', '1,,2']) {
      expect(() => parseSelection(input, chapters), throwsFormatException);
    }
  });
  test('markup preserves text, ruby, links, images and unknown tags', () {
    final result = novelText(
      '本来 <tag> &amp;\n[chapter:第一章][[rb:漢字 > かんじ]]\n'
      '[[jumpuri:作者 > https://example.com]][newpage][pixivimage:123-2][uploadedimage:abc][unknown:x]',
    );
    expect(result, contains('本来 <tag> &amp;'));
    expect(result, contains('漢字（かんじ）'));
    expect(result, contains('作者（https://example.com）'));
    expect(result, contains('https://www.pixiv.net/artworks/123'));
    expect(result, contains('[unknown:x]'));
    expect(plainDescription('甲<br>乙 &amp; 丙'), '甲\n乙 & 丙');
  });
  test('portable filenames reject controls, reserved names and long paths', () {
    expect(safeFilename(' ../con. '), '_con');
    expect(safeFilename('a/b:c?d'), 'a_b_c_d');
    expect(safeFilename('🌸' * 100).runes.length, 72);
    expect(safeFilename('...'), 'Pixiv 小说');
  });
  test(
    'complete series beyond 30 chapters, selected in original order',
    () async {
      final requests = <String>[];
      final api = PixivClient(
        MockClient((request) async {
          requests.add(request.url.path);
          if (request.url.path.endsWith('content_titles')) {
            return ok(
              List.generate(
                65,
                (i) => {
                  'id': '${i + 1}',
                  'title': '章 ${i + 1}',
                  'order': i + 1,
                  'available': true,
                },
              ),
            );
          }
          if (request.url.path == '/ajax/novel/series/1') {
            return ok({'title': '测试系列', 'userName': '作者', 'total': 65});
          }
          return ok(novelBody(request.url.pathSegments.last));
        }),
        pause: Duration.zero,
      );
      final work = await api.load(const WorkLink(WorkKind.series, '1'));
      expect(work.chapters.length, 65);
      final result = await api.extract(work, {
        '65',
        '31',
        '2',
      }, cancel: Cancellation());
      expect(result.map((n) => n.id), ['2', '31', '65']);
      expect(requests.where((p) => p.endsWith('content_titles')).length, 1);
      api.dispose();
    },
  );
  test('incomplete and duplicate series are not silently exported', () async {
    for (final data in [
      [
        {'id': '1', 'title': '甲'},
      ],
      [
        {'id': '1', 'title': '甲'},
        {'id': '1', 'title': '重复'},
      ],
    ]) {
      final api = PixivClient(
        MockClient(
          (r) async => r.url.path.endsWith('content_titles')
              ? ok(data)
              : ok({'title': '系列', 'total': 2}),
        ),
      );
      await expectLater(
        api.load(const WorkLink(WorkKind.series, '1')),
        throwsA(isA<PixivException>()),
      );
      api.dispose();
    }
  });
  test('login signals, deleted works and invalid JSON are distinct', () async {
    for (final code in [401, 403, 404]) {
      final api = PixivClient(MockClient((r) async => http.Response('', code)));
      await expectLater(
        api.novel('1'),
        throwsA(code == 404 ? isA<PixivException>() : isA<LoginRequired>()),
      );
      api.dispose();
    }
    final api = PixivClient(
      MockClient((r) async => http.Response('<html>captcha</html>', 200)),
    );
    await expectLater(api.novel('1'), throwsA(isA<PixivException>()));
    api.dispose();
  });
  test(
    'empty body requires login and logged in empty body never exports',
    () async {
      final api = PixivClient(
        MockClient((r) async => ok({'title': '隐藏', 'content': ''})),
      );
      await expectLater(api.novel('1'), throwsA(isA<LoginRequired>()));
      api.setSession('123456_test-session');
      await expectLater(api.novel('1'), throwsA(isA<PixivException>()));
      expect(() => api.setSession('123\r\nCookie: x'), throwsFormatException);
      api.dispose();
    },
  );
  test(
    'failed chapters stop extraction and cancellation stops requests',
    () async {
      var count = 0;
      final api = PixivClient(
        MockClient((r) async {
          count++;
          return r.url.path.endsWith('/2')
              ? http.Response('', 404)
              : ok(novelBody(r.url.pathSegments.last));
        }),
        pause: Duration.zero,
      );
      final work = Work(
        title: '合并',
        author: '测试',
        chapters: chapters
            .take(3)
            .map(
              (c) => Chapter(id: '${c.order}', title: c.title, order: c.order),
            )
            .toList(),
        link: const WorkLink(WorkKind.series, '1'),
      );
      await expectLater(
        api.extract(work, {'1', '2', '3'}, cancel: Cancellation()),
        throwsA(isA<PixivException>()),
      );
      expect(count, 2);
      final cancelled = Cancellation()..cancel();
      await expectLater(
        api.extract(work, {'1'}, cancel: cancelled),
        throwsA(isA<Cancelled>()),
      );
      expect(count, 2);
      api.dispose();
    },
  );
  test('changing session clears cached content', () async {
    var count = 0;
    final api = PixivClient(
      MockClient((r) async {
        count++;
        return ok(novelBody('1'));
      }),
    );
    await api.novel('1');
    await api.novel('1');
    expect(count, 1);
    api.setSession(null);
    await api.novel('1');
    expect(count, 2);
    api.dispose();
  });
}
