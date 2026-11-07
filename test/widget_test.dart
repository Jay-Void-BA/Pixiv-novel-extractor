import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shiori/main.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  for (final width in [390.0, 1440.0]) {
    testWidgets('usable empty state at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const ShioriApp());
      await tester.pumpAndSettle();
      expect(find.text('你的故事，随处可读。'), findsOneWidget);
      expect(find.text('读取作品'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '导出 TXT'),
      );
      expect(button.onPressed, isNull);
      await tester.enterText(
        find.byType(TextField).first,
        'https://evil.example/novel/1',
      );
      await tester.tap(find.text('读取作品'));
      await tester.pumpAndSettle();
      expect(find.text('请输入 Pixiv 小说链接、系列链接或小说 ID。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
