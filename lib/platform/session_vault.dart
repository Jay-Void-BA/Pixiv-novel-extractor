import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../core/models.dart';

class RestoredSession {
  const RestoredSession(this.session, {this.discarded = false});
  final String? session;
  final bool discarded;
}

/// Platform vaults own encryption keys; Dart never handles raw key bytes.
class SessionVault {
  SessionVault({
    bool? android,
    FlutterSecureStorage? storage,
    DateTime Function()? now,
    this.storageKey = defaultStorageKey,
  }) : _android = android ?? Platform.isAndroid,
       _storage =
           storage ??
           const FlutterSecureStorage(
             iOptions: IOSOptions(
               accountName: 'io.github.jayvoid.shiori',
               accessibility: KeychainAccessibility.unlocked_this_device,
               synchronizable: false,
             ),
             // Distributed macOS builds have no provisioning profile or shared group.
             mOptions: MacOsOptions(
               accountName: 'io.github.jayvoid.shiori',
               usesDataProtectionKeychain: false,
               synchronizable: false,
             ),
             wOptions: WindowsOptions(useBackwardCompatibility: false),
           ),
       _now = now ?? DateTime.now;

  static const channel = MethodChannel('shiori/session_vault');
  static const defaultStorageKey = 'io.github.jayvoid.shiori.pixiv-session.v1';
  final String storageKey;
  static const maxAge = Duration(days: 30);
  final bool _android;
  final FlutterSecureStorage _storage;
  final DateTime Function() _now;

  Future<T> _platform<T>(Future<T> Function() call) async {
    try {
      return await call();
    } catch (_) {
      // Native/library error strings may contain record excerpts: never relay them.
      throw const PixivException('系统安全存储不可用。请解锁系统密钥库后重试；不会以明文保存。');
    }
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object>? arguments]) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on PlatformException {
      throw const PixivException('系统安全存储不可用，请重试。登录信息不会以明文保存。');
    } on MissingPluginException {
      throw const PixivException('此平台尚未提供安全会话存储。');
    }
  }

  Future<RestoredSession> read() async {
    if (!_android) {
      final encoded = await _platform(() => _storage.read(key: storageKey));
      if (encoded == null) return const RestoredSession(null);
      try {
        if (encoded.length > 4096) throw const FormatException();
        final data = jsonDecode(encoded);
        if (data is! Map ||
            data['version'] != 1 ||
            data['session'] is! String ||
            data['savedAt'] is! int ||
            data['expiresAt'] is! int) {
          throw const FormatException();
        }
        final session = data['session'] as String;
        final saved = data['savedAt'] as int;
        final expires = data['expiresAt'] as int;
        final now = _now().millisecondsSinceEpoch;
        if (!RegExp(r'^[A-Za-z0-9_%.-]{8,512}$').hasMatch(session) ||
            saved <= 0 ||
            saved > now ||
            expires <= now ||
            expires != saved + maxAge.inMilliseconds) {
          throw const FormatException();
        }
        return RestoredSession(session);
      } on FormatException {
        await delete();
        return const RestoredSession(null, discarded: true);
      }
    }
    final result = await _invoke<Map<Object?, Object?>>('read');
    final value = result?['session'];
    if (value != null &&
        (value is! String ||
            !RegExp(r'^[A-Za-z0-9_%.-]{8,512}$').hasMatch(value))) {
      await delete();
      return const RestoredSession(null, discarded: true);
    }
    return RestoredSession(
      value as String?,
      discarded: result?['discarded'] == true,
    );
  }

  Future<void> write(String session) async {
    if (!RegExp(r'^[A-Za-z0-9_%.-]{8,512}$').hasMatch(session)) {
      throw const FormatException('PHPSESSID 格式无效。只需粘贴该 Cookie 的值。');
    }
    if (_android) {
      await _invoke<void>('write', {'session': session});
      return;
    }
    final saved = _now().millisecondsSinceEpoch;
    final encoded = jsonEncode({
      'version': 1,
      'session': session,
      'savedAt': saved,
      'expiresAt': saved + maxAge.inMilliseconds,
    });
    await _platform(() async {
      try {
        await _storage.write(key: storageKey, value: encoded);
        if (await _storage.read(key: storageKey) != encoded) {
          throw const FormatException();
        }
      } catch (_) {
        await _storage.delete(key: storageKey);
        rethrow;
      }
    });
  }

  Future<void> delete() async {
    try {
      if (_android) {
        await _invoke<void>('delete');
        return;
      }
      await _platform(() async {
        await _storage.delete(key: storageKey);
        if (await _storage.read(key: storageKey) != null) {
          throw const FormatException();
        }
      });
    } catch (_) {
      throw const PixivException('无法确认保存的会话已删除。请解锁系统密钥库后，再次选择「退出并清除会话」。');
    }
  }
}
