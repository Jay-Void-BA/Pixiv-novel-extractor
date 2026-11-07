import 'package:flutter/services.dart';
import '../core/models.dart';

class RestoredSession {
  const RestoredSession(this.session, {this.discarded = false});
  final String? session;
  final bool discarded;
}

/// Android owns the key and authenticated file; Dart never handles raw key bytes.
class SessionVault {
  static const channel = MethodChannel('shiori/session_vault');

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
    final result = await _invoke<Map<Object?, Object?>>('read');
    final value = result?['session'];
    if (value != null &&
        (value is! String || !RegExp(r'^[A-Za-z0-9_%.-]{8,512}$').hasMatch(value))) {
      await delete();
      return const RestoredSession(null, discarded: true);
    }
    return RestoredSession(value as String?, discarded: result?['discarded'] == true);
  }

  Future<void> write(String session) async {
    if (!RegExp(r'^[A-Za-z0-9_%.-]{8,512}$').hasMatch(session)) {
      throw const FormatException('PHPSESSID 格式无效。只需粘贴该 Cookie 的值。');
    }
    await _invoke<void>('write', {'session': session});
  }

  Future<void> delete() async => _invoke<void>('delete');
}
