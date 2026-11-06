import 'package:html/parser.dart' as html;

String plainDescription(String value) =>
    html
        .parseFragment(
          value.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n'),
        )
        .text
        ?.trim() ??
    '';

/// Pixiv's novel body is plain text with its own markup, not HTML.
/// Keep unknown tags visible rather than silently deleting author content.
String novelText(String input) {
  return input
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAllMapped(
        RegExp(r'\[chapter:([^\]]+)\]'),
        (m) => '\n\n${m[1]}\n\n',
      )
      .replaceAll('[newpage]', '\n\n──────────\n\n')
      .replaceAllMapped(
        RegExp(r'\[\[rb:([^>\]]+)\s*>\s*([^\]]+)\]\]'),
        (m) => '${m[1]!.trim()}（${m[2]!.trim()}）',
      )
      .replaceAllMapped(
        RegExp(r'\[\[jumpuri:([^>\]]+)\s*>\s*([^\]]+)\]\]'),
        (m) => '${m[1]!.trim()}（${m[2]!.trim()}）',
      )
      .replaceAllMapped(RegExp(r'\[jump:(\d+)\]'), (m) => '［跳转至第 ${m[1]} 页］')
      .replaceAllMapped(
        RegExp(r'\[pixivimage:(\d+)(?:-(\d+))?\]'),
        (m) =>
            '［插图：https://www.pixiv.net/artworks/${m[1]}${m[2] == null ? '' : ' · 第 ${m[2]} 页'}］',
      )
      .replaceAllMapped(
        RegExp(r'\[uploadedimage:([^\]]+)\]'),
        (m) => '［作者插图 ${m[1]}，请在原文查看］',
      )
      .trim();
}

String safeFilename(String title) {
  var name = title
      .replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'^[ .]+|[ .]+$'), '')
      .trim();
  if (name.isEmpty) name = 'Pixiv 小说';
  // Truncate by Unicode code point to avoid splitting surrogate pairs.
  name = String.fromCharCodes(name.runes.take(72));
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(name)) {
    name = '_$name';
  }
  return name;
}
