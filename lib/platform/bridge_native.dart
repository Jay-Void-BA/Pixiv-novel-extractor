import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../core/exporter.dart';
import '../core/models.dart';
import 'mobile_login.dart';
import 'session_vault.dart';

class PlatformBridge {
  PlatformBridge({bool? supportsSessionStorage})
    : supportsSessionStorage = supportsSessionStorage ?? Platform.isAndroid;
  final http.Client client = http.Client();
  HttpServer? _loginServer;
  Completer<String?>? _loginResult;
  final _vault = SessionVault();
  String? _session;
  bool loggedIn = false;
  bool rememberSession = false;
  String? startupNotice;
  final bool supportsSessionStorage;
  String? get activeSession => _session;

  Future<void> init() async {
    if (!supportsSessionStorage) return;
    try {
      final restored = await _vault.read();
      _session = restored.session;
      loggedIn = _session != null;
      rememberSession = loggedIn;
      if (loggedIn) startupNotice = '已恢复加密保存的会话，将在请求时验证有效性。';
      if (restored.discarded) {
        startupNotice = '保存的会话已过期或无法验证，已清除，请重新登录。';
      }
    } catch (_) {
      startupNotice = '无法读取系统安全存储。可重新登录；不会使用明文保存。';
    }
  }

  Future<String?> login(BuildContext context) async {
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        return await Navigator.of(context).push<String>(
          MaterialPageRoute(
            builder: (_) => MobileLogin(rememberSession: rememberSession),
          ),
        );
      } finally {
        await WebViewCookieManager().clearCookies();
      }
    }
    await cancelLogin();
    final token = base64Url
        .encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _loginServer = server;
    final result = Completer<String?>();
    _loginResult = result;
    server.listen((request) async {
      final response = request.response;
      response.headers.set('Cache-Control', 'no-store');
      response.headers.set('X-Content-Type-Options', 'nosniff');
      final origin = request.headers.value('origin');
      if (origin != null &&
          RegExp(
            r'^(chrome|moz)-extension://[a-zA-Z0-9-]+$',
          ).hasMatch(origin)) {
        response.headers.set('Access-Control-Allow-Origin', origin);
        response.headers.set('Vary', 'Origin');
        response.headers.set(
          'Access-Control-Allow-Headers',
          'Authorization, Content-Type',
        );
        response.headers.set('Access-Control-Allow-Methods', 'POST, OPTIONS');
        response.headers.set('Access-Control-Allow-Private-Network', 'true');
      } else if (origin != null) {
        response.statusCode = 403;
        await response.close();
        return;
      }
      if (request.method == 'OPTIONS' && request.uri.path == '/session') {
        response.statusCode = 204;
      } else if (request.method == 'GET' && request.uri.path == '/pair') {
        response.headers.contentType = ContentType.html;
        response.headers.set(
          'Content-Security-Policy',
          "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
        );
        response.write(pairingHtml);
      } else if (request.method == 'POST' &&
          request.uri.path == '/session' &&
          request.headers.value('authorization') == 'Bearer $token') {
        try {
          final bytes = <int>[];
          await for (final chunk in request.timeout(
            const Duration(seconds: 5),
          )) {
            bytes.addAll(chunk);
            if (bytes.length > 2048) throw const FormatException();
          }
          final data = jsonDecode(utf8.decode(bytes));
          final session = data is Map ? data['session'] : null;
          if (session is! String ||
              !RegExp(r'^[A-Za-z0-9_%.-]{8,512}$').hasMatch(session)) {
            throw const FormatException();
          }
          response.statusCode = 200;
          response.write('{"ok":true}');
          if (!result.isCompleted) result.complete(session);
        } catch (_) {
          response.statusCode = 400;
        }
      } else {
        response.statusCode = 403;
      }
      await response.close();
    });
    try {
      final opened = await launchUrl(
        Uri.parse('http://127.0.0.1:${server.port}/pair#$token'),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) throw const PixivException('无法唤起浏览器。可使用「导入会话」作为备用方式。');
      return await result.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => null,
      );
    } finally {
      if (identical(_loginServer, server)) {
        _loginServer = null;
        _loginResult = null;
      }
      await server.close(force: true);
    }
  }

  Future<void> cancelLogin() async {
    final result = _loginResult;
    if (result != null && !result.isCompleted) result.complete(null);
    await _loginServer?.close(force: true);
    _loginServer = null;
    _loginResult = null;
  }

  Future<void> importSession(String value) async {
    if (!RegExp(r'^[A-Za-z0-9_%.-]{8,512}$').hasMatch(value)) {
      throw const FormatException('PHPSESSID 格式无效。只需粘贴该 Cookie 的值。');
    }
    _session = value;
    loggedIn = true;
    if (rememberSession) {
      try {
        await _vault.write(value);
      } catch (_) {
        rememberSession = false;
        throw const PixivException('会话已连接，但加密保存失败。本次仅保留在内存，请重试安全保存。');
      }
    }
  }

  Future<void> setRememberSession(bool enabled) async {
    if (!supportsSessionStorage) {
      throw const PixivException('此平台尚未提供安全会话存储。');
    }
    if (enabled) {
      if (_session != null) await _vault.write(_session!);
    } else {
      await _vault.delete();
    }
    rememberSession = enabled;
  }

  Future<void> invalidateSession() async {
    _session = null;
    loggedIn = false;
    if (supportsSessionStorage) await _vault.delete();
  }

  Future<void> logout() async {
    loggedIn = false;
    _session = null;
    rememberSession = false;
    if (supportsSessionStorage) await _vault.delete();
    await cancelLogin();
    if (Platform.isIOS || Platform.isAndroid) {
      await WebViewCookieManager().clearCookies();
    }
  }

  /// Returns false if the user dismisses the save dialog or share sheet.
  Future<bool> save(ExportFile file, {Rect? shareOrigin}) async {
    if (Platform.isAndroid || Platform.isIOS) {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/${file.name}';
      await File(path).writeAsBytes(file.bytes, flush: true);
      try {
        final result = await SharePlus.instance.share(
          ShareParams(
            files: [XFile(path, mimeType: file.mime)],
            title: file.name,
            sharePositionOrigin: shareOrigin ?? const Rect.fromLTWH(0, 0, 1, 1),
          ),
        );
        return result.status != ShareResultStatus.dismissed;
      } finally {
        // The platform share implementation copies the attachment before returning.
        if (await File(path).exists()) await File(path).delete();
      }
    }
    final ext = file.name.split('.').last;
    final location = await getSaveLocation(
      suggestedName: file.name,
      acceptedTypeGroups: [
        XTypeGroup(label: ext.toUpperCase(), extensions: [ext]),
      ],
    );
    if (location == null) return false;
    await XFile.fromData(
      file.bytes,
      mimeType: file.mime,
      name: file.name,
    ).saveTo(location.path);
    return true;
  }

  void dispose() {
    _session = null;
    unawaited(cancelLogin());
  }
}

const pairingHtml =
    '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>连接 Shiori</title><style>body{font:17px/1.9 system-ui;background:#f6f5f1;color:#242a31;max-width:640px;margin:12vh auto;padding:32px}h1{font-size:34px}p{color:#53616a}#shiori-connect{padding:14px 22px;background:#176755;color:white;border:0;border-radius:10px;font-size:17px;cursor:pointer}</style><h1>连接你的 Pixiv 会话</h1><p>这是 Shiori 在本机打开的临时登录页面。安装随应用提供的 Shiori Bridge 浏览器扩展后，此处会出现连接按钮。点击按钮，在 Pixiv 官方网站完成登录，并在扩展的确认页允许将会话发送给本机应用。</p><p>会话仅保留在内存中；不会上传到第三方服务器。请不要向他人分享此页面的地址。</p><p>尚未安装扩展？请按 Release 中 browser-bridge.zip 的说明安装，随后刷新此页。也可返回应用选择「导入会话」。</p><p>连接有效期：5 分钟。取消登录请返回应用。</p></html>''';
