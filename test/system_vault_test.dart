import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiori/platform/session_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 11, 7);
  SessionVault vault([DateTime? time]) => SessionVault(android: false, now: () => time ?? now);
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('system vault restores an authenticated OS record across instances', () async {
    await vault().write('synthetic_system_session_12345');
    expect((await vault().read()).session, 'synthetic_system_session_12345');
    await vault().delete();
    expect((await vault().read()).session, isNull);
  });

  test('system record expires at thirty days and is deleted', () async {
    await vault().write('synthetic_system_session_12345');
    final restored = await vault(now.add(const Duration(days: 30))).read();
    expect(restored.discarded, isTrue);
    expect((await vault().read()).session, isNull);
  });

  test('corrupt, unsupported and invalid session records fail closed', () async {
    for (final encoded in ['malformed synthetic JSON', jsonEncode({'version': 2}),
      jsonEncode({'version': 1, 'session': 'bad\r\ncookie',
        'savedAt': now.millisecondsSinceEpoch,
        'expiresAt': now.add(const Duration(days: 30)).millisecondsSinceEpoch})]) {
      FlutterSecureStorage.setMockInitialValues({SessionVault.defaultStorageKey: encoded});
      final restored = await vault().read();
      expect(restored.session, isNull);
      expect(restored.discarded, isTrue);
      expect(await const FlutterSecureStorage().read(key: SessionVault.defaultStorageKey), isNull);
    }
  });

  test('clock rollback does not extend a remembered session', () async {
    await vault().write('synthetic_system_session_12345');
    expect((await vault(now.subtract(const Duration(seconds: 1))).read()).discarded, isTrue);
  });
}
