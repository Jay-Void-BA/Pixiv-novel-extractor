import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiori/core/exporter.dart';
import 'package:shiori/core/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sample = [
    Novel(
      id: '1',
      title: '第一章 · 雨の栞',
      author: '测试作者',
      content: '中文正文。日本語の小説。\n[[rb:物語 > ものがたり]]',
      description: '简介<br>第二行',
    ),
    Novel(
      id: '2',
      title: '第二章',
      author: '测试作者',
      content: '[chapter:重逢]\n繁體中文。',
    ),
  ];
  test(
    'UTF-8 text has ordered chapters, metadata and optional descriptions',
    () async {
      final file = await NovelExporter().export(
        '测试/选集',
        sample,
        const ExportOptions(descriptions: true),
      );
      expect(file.name, '测试_选集.txt');
      expect(file.bytes.take(3), [239, 187, 191]);
      final content = utf8.decode(file.bytes.skip(3).toList());
      expect(content.indexOf('第一章'), lessThan(content.indexOf('第二章')));
      expect(content, contains('https://www.pixiv.net/novel/show.php?id=1'));
      expect(content, contains('简介\n第二行'));
      expect(content, contains('物語（ものがたり）'));
      final minimal = await NovelExporter().export(
        '测试',
        sample,
        const ExportOptions(metadata: false),
      );
      expect(utf8.decode(minimal.bytes), isNot(contains('原文：')));
    },
  );
  test(
    'PDF embeds CJK and handles over twenty pages and a long paragraph',
    () async {
      final longNovel = Novel(
        id: '3',
        title: '长篇排版测试',
        author: '测试作者',
        content:
            '${'中文日本語の長い文章。' * 4200}\n\n${List.filled(600, '普通分段内容。').join('\n')}',
      );
      final file = await NovelExporter().export('长篇', [
        ...sample,
        longNovel,
      ], const ExportOptions(format: ExportFormat.pdf));
      expect(latin1.decode(file.bytes.take(5).toList()), '%PDF-');
      expect(file.bytes.length, greaterThan(30000));
      final out = Directory('build/test-exports')..createSync(recursive: true);
      File('${out.path}/cjk-long.pdf').writeAsBytesSync(file.bytes);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test('empty exports are rejected', () async {
    await expectLater(
      NovelExporter().export('空', [], const ExportOptions()),
      throwsA(isA<PixivException>()),
    );
  });
}
