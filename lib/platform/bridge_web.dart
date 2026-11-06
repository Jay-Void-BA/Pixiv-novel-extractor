import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;
import '../core/exporter.dart';
import '../core/models.dart';

class _LocalClient extends http.BaseClient {
  _LocalClient(this.bridge);
  final PlatformBridge bridge;
  final _inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.host != 'www.pixiv.net' || request.method != 'GET') {
      throw http.ClientException('Unsupported target');
    }
    final path =
        request.url.path +
        (request.url.hasQuery ? '?${request.url.query}' : '');
    final uri = Uri.base
        .resolve('/api/pixiv')
        .replace(queryParameters: {'path': path});
    final proxy = http.Request('GET', uri)
      ..headers['Authorization'] = 'Bearer ${bridge._token}';
    return _inner.send(proxy);
  }

  @override
  void close() => _inner.close();
}

class PlatformBridge {
  PlatformBridge() {
    client = _LocalClient(this);
  }
  late final http.Client client;
  final _control = http.Client();
  String? _token;
  bool loggedIn = false;
  int _loginGeneration = 0;
  Future<void> init() async {
    try {
      final response = await _control
          .get(Uri.base.resolve('/api/config'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) throw const FormatException();
      final config = jsonDecode(response.body) as Map<String, dynamic>;
      _token = config['token'] as String;
      loggedIn = config['loggedIn'] == true;
    } catch (_) {
      throw const PixivException('请通过随包提供的本地服务启动 Web 版。普通静态托管无法访问 Pixiv 接口。');
    }
  }

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $_token',
    'Content-Type': 'application/json',
  };

  Future<String?> login(BuildContext context) async {
    final generation = ++_loginGeneration;
    // Open synchronously from the user gesture to avoid popup blocking.
    final popup = web.window.open('about:blank', '_blank');
    try {
      final response = await _control.post(
        Uri.base.resolve('/api/login'),
        headers: _headers,
      );
      if (response.statusCode != 200) throw const PixivException('本地登录服务不可用。');
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final url = data['url'] as String;
      if (popup == null) throw const PixivException('浏览器拦截了登录窗口，请允许弹出窗口后重试。');
      popup.location.href = url;
      final deadline = DateTime.now().add(const Duration(minutes: 5));
      while (generation == _loginGeneration &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (generation != _loginGeneration) break;
        final status = await _control.get(
          Uri.base.resolve('/api/session'),
          headers: _headers,
        );
        if (status.statusCode == 200 &&
            (jsonDecode(status.body) as Map)['loggedIn'] == true) {
          loggedIn = true;
          return 'local-proxy-session'; // The actual cookie never enters the web UI.
        }
      }
      return null;
    } catch (_) {
      popup?.close();
      rethrow;
    }
  }

  Future<void> cancelLogin() async {
    _loginGeneration++;
    if (_token != null) {
      await _control.delete(Uri.base.resolve('/api/login'), headers: _headers);
    }
  }

  Future<void> importSession(String value) async {
    if (value == 'local-proxy-session') {
      loggedIn = true;
      return;
    }
    final response = await _control.post(
      Uri.base.resolve('/api/session'),
      headers: _headers,
      body: jsonEncode({'session': value}),
    );
    if (response.statusCode != 200) throw const PixivException('本地服务拒绝了会话。');
    loggedIn = true;
  }

  Future<void> logout() async {
    await cancelLogin();
    final response = await _control.delete(
      Uri.base.resolve('/api/session'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw const PixivException('本地服务未能清除会话，请关闭本地服务。');
    }
    loggedIn = false;
  }

  Future<bool> save(ExportFile file, {Rect? shareOrigin}) async {
    final blob = web.Blob(
      [file.bytes.toJS].toJS,
      web.BlobPropertyBag(type: file.mime),
    );
    final url = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = file.name;
    web.document.body!.append(anchor);
    anchor.click();
    anchor.remove();
    Timer(const Duration(seconds: 30), () => web.URL.revokeObjectURL(url));
    return true;
  }

  void dispose() {
    _loginGeneration++;
    _control.close();
  }
}
