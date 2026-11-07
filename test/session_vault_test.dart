import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiori/core/models.dart';
import 'package:shiori/platform/session_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final vault = SessionVault();
  tearDown(() => messenger.setMockMethodCallHandler(SessionVault.channel, null));

  test('restores a session only through the native vault', () async {
    messenger.setMockMethodCallHandler(SessionVault.channel, (call) async {
      expect(call.method, 'read');
      return {'session': 'synthetic_session_12345', 'discarded': false};
    });
    expect((await vault.read()).session, 'synthetic_session_12345');
  });

  test('malformed restored value is deleted rather than used', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(SessionVault.channel, (call) async {
      calls.add(call.method);
      return call.method == 'read' ? {'session': 'invalid\r\ncookie'} : null;
    });
    final restored = await vault.read();
    expect(restored.session, isNull);
    expect(restored.discarded, isTrue);
    expect(calls, ['read', 'delete']);
  });

  test('native failures never expose platform details or secrets', () async {
    messenger.setMockMethodCallHandler(SessionVault.channel, (call) async {
      throw PlatformException(code: 'failure', message: 'synthetic_secret_do_not_log');
    });
    await expectLater(vault.write('synthetic_session_12345'), throwsA(
      isA<PixivException>().having((error) => error.message, 'safe error',
        isNot(contains('synthetic_secret_do_not_log'))),
    ));
  });

  test('invalid input never reaches the native channel', () async {
    messenger.setMockMethodCallHandler(SessionVault.channel, (call) async {
      fail('Invalid input reached native storage');
    });
    await expectLater(vault.write('bad\r\ncookie'), throwsFormatException);
  });
}
