import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiori/core/models.dart';
import 'package:shiori/platform/bridge_native.dart';
import 'package:shiori/platform/session_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late PlatformBridge bridge;
  String? stored;
  late List<String> calls;
  setUp(() {
    stored = null;
    calls = [];
    bridge = PlatformBridge(supportsSessionStorage: true);
    messenger.setMockMethodCallHandler(SessionVault.channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'read': return {'session': stored, 'discarded': false};
        case 'write':
          stored = (call.arguments as Map)['session'] as String;
          break;
        case 'delete':
          stored = null;
          break;
      }
      return null;
    });
  });
  tearDown(() {
    bridge.dispose();
    bridge.client.close();
    messenger.setMockMethodCallHandler(SessionVault.channel, null);
  });

  test('default login stays in memory until explicit opt-in', () async {
    await bridge.init();
    await bridge.importSession('synthetic_session_12345');
    expect(bridge.loggedIn, isTrue);
    expect(bridge.rememberSession, isFalse);
    expect(stored, isNull);
    expect(calls, ['read']);
    await bridge.setRememberSession(true);
    expect(stored, 'synthetic_session_12345');
    await bridge.setRememberSession(false);
    expect(stored, isNull);
    expect(bridge.loggedIn, isTrue);
  });

  test('restored native cookie is used instead of the web proxy sentinel', () async {
    stored = 'synthetic_session_12345';
    await bridge.init();
    expect(bridge.activeSession, stored);
    expect(bridge.activeSession, isNot('local-proxy-session'));
    expect(bridge.loggedIn, isTrue);
    expect(bridge.rememberSession, isTrue);
    await bridge.logout();
    expect(stored, isNull);
    expect(bridge.activeSession, isNull);
    expect(bridge.rememberSession, isFalse);
  });

  test('server-rejected session is deleted before another login', () async {
    await bridge.setRememberSession(true);
    await bridge.importSession('synthetic_session_12345');
    await bridge.invalidateSession();
    expect(stored, isNull);
    expect(bridge.activeSession, isNull);
    expect(bridge.loggedIn, isFalse);
    await bridge.importSession('synthetic_new_session_12345');
    expect(stored, 'synthetic_new_session_12345');
  });

  test('storage failure does not silently claim persistence or save plaintext', () async {
    await bridge.setRememberSession(true);
    messenger.setMockMethodCallHandler(SessionVault.channel, (_) async {
      throw PlatformException(code: 'unavailable');
    });
    await expectLater(bridge.importSession('synthetic_session_12345'),
      throwsA(isA<PixivException>()));
    expect(bridge.activeSession, 'synthetic_session_12345');
    expect(bridge.loggedIn, isTrue);
    expect(bridge.rememberSession, isFalse);
    expect(stored, isNull);
  });
}
