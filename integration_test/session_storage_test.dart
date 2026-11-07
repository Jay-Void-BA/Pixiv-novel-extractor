import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shiori/platform/session_vault.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real OS secure storage round trip, expiry, and deletion', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Secure storage test'))),
    );
    // A test-only record; never overwrite or log the user's session record.
    const key = 'io.github.jayvoid.shiori.integration-session-v1';
    final vault = SessionVault(android: false, storageKey: key);
    try {
      await vault.delete();
      expect((await vault.read()).session, isNull);
      await vault.write('synthetic_os_session_12345678');
      final recreated = SessionVault(android: false, storageKey: key);
      expect((await recreated.read()).session, 'synthetic_os_session_12345678');
      final expired = SessionVault(
        android: false,
        storageKey: key,
        now: () => DateTime.now().add(const Duration(days: 31)),
      );
      expect((await expired.read()).discarded, isTrue);
      expect((await vault.read()).session, isNull);
      await vault.write('synthetic_os_session_12345678');
      await vault.delete();
      expect((await vault.read()).session, isNull);
    } finally {
      await vault.delete();
    }
  });
}
