import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'models.dart';
import 'novel_text.dart';

enum ExportFormat { txt, pdf }

class ExportOptions {
  const ExportOptions({
    this.format = ExportFormat.txt,
    this.metadata = true,
    this.descriptions = false,
    this.fontSize = 12,
  });
  final ExportFormat format;
  final bool metadata;
  final bool descriptions;
  final double fontSize;
}

class ExportFile {
  const ExportFile(this.name, this.bytes, this.mime);
  final String name;
  final Uint8List bytes;
  final String mime;
}

class NovelExporter {
  Future<ExportFile> export(
    String title,
    List<Novel> novels,
    ExportOptions options,
  ) async {
    if (novels.isEmpty) throw const PixivException('没有可导出的正文。');
    final filename = safeFilename(title);
    if (options.format == ExportFormat.txt) {
      final text = StringBuffer('$title\n${'═' * 32}\n\n');
      for (var i = 0; i < novels.length; i++) {
        final n = novels[i];
        if (i > 0) text.write('\n\n${'─' * 32}\n\n');
        text.writeln(n.title);
        if (options.metadata) text.write('作者：${n.author}\n原文：${n.url}\n');
        if (options.descriptions && n.description.isNotEmpty) {
          text.write('\n${plainDescription(n.description)}\n');
        }
        text.write('\n${novelText(n.content)}\n');
      }
      // UTF-8 BOM keeps Windows editors' encoding detection reliable.
      return ExportFile(
        '$filename.txt',
        Uint8List.fromList([0xef, 0xbb, 0xbf, ...utf8.encode(text.toString())]),
        'text/plain',
      );
    }
    final font = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf'),
    );
    final doc = pw.Document(
      title: title,
      author: novels.map((n) => n.author).toSet().join('、'),
      creator: 'Shiori · Pixiv Novel Extractor',
    );
    for (final n in novels) {
      // Paragraph wraps Text in a non-spanning Container. Use Text directly:
      // a single very long author paragraph must also span multiple pages.
      final paragraphs = novelText(n.content).split('\n');
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          maxPages: 10000,
          margin: const pw.EdgeInsets.fromLTRB(46, 48, 46, 48),
          theme: pw.ThemeData.withFont(
            base: font,
            bold: font,
            italic: font,
            boldItalic: font,
          ),
          footer: (c) => pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text(
              '${c.pageNumber} / ${c.pagesCount}',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
            ),
          ),
          build: (_) => [
            pw.Header(
              level: 0,
              text: n.title,
              textStyle: pw.TextStyle(font: font, fontSize: 21),
            ),
            if (options.metadata) ...[
              pw.Text(
                '作者：${n.author}',
                style: const pw.TextStyle(fontSize: 10),
              ),
              pw.UrlLink(
                destination: n.url,
                child: pw.Text(
                  n.url,
                  style: const pw.TextStyle(
                    fontSize: 9,
                    color: PdfColors.grey700,
                  ),
                ),
              ),
              pw.SizedBox(height: 18),
            ],
            if (options.descriptions && n.description.isNotEmpty) ...[
              for (final chunk in _boundedText(plainDescription(n.description)))
                pw.Text(
                  chunk,
                  overflow: pw.TextOverflow.span,
                  style: const pw.TextStyle(
                    fontSize: 10,
                    color: PdfColors.grey700,
                  ),
                ),
              pw.SizedBox(height: 14),
            ],
            for (final p in paragraphs)
              if (p.trim().isEmpty)
                pw.SizedBox(height: 8)
              else
                for (final chunk in _boundedText(p))
                  pw.Text(
                    chunk,
                    overflow: pw.TextOverflow.span,
                    style: pw.TextStyle(
                      fontSize: options.fontSize,
                      lineSpacing: 4,
                    ),
                  ),
          ],
        ),
      );
    }
    return ExportFile('$filename.pdf', await doc.save(), 'application/pdf');
  }
}

/// Bound the PDF line breaker's work on huge paragraphs without spaces. No
/// characters are dropped; additional soft breaks affect only the PDF layout.
Iterable<String> _boundedText(String text) sync* {
  final runes = text.runes.toList();
  for (var start = 0; start < runes.length; start += 400) {
    final end = (start + 400).clamp(0, runes.length);
    yield String.fromCharCodes(runes.sublist(start, end));
  }
}
