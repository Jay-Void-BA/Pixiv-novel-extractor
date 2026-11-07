import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

class MobileLogin extends StatefulWidget {
  const MobileLogin({super.key, this.rememberSession = false});
  final bool rememberSession;
  @override
  State<MobileLogin> createState() => _MobileLoginState();
}

class _MobileLoginState extends State<MobileLogin> {
  late final WebViewController _controller;
  bool _reading = false;
  String? _error;
  static const _cookies = MethodChannel('shiori/pixiv_cookies');

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            return uri != null &&
                    (uri.scheme == 'https' || request.url == 'about:blank')
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onPageFinished: (url) async {
            final uri = Uri.tryParse(url);
            if (uri?.host == 'www.pixiv.net') await _checkLogin();
          },
          onWebResourceError: (error) {
            if (mounted && error.isForMainFrame == true) {
              setState(() => _error = '登录页面加载失败，请检查网络后刷新。');
            }
          },
        ),
      )
      ..loadRequest(
        Uri.parse(
          'https://accounts.pixiv.net/login?return_to=https%3A%2F%2Fwww.pixiv.net%2F',
        ),
      );
  }

  Future<void> _checkLogin() async {
    if (_reading) return;
    _reading = true;
    try {
      final session = await _cookies.invokeMethod<String>('getSession');
      if (mounted && session != null && session.isNotEmpty) {
        Navigator.pop(context, session);
      }
    } on PlatformException {
      if (mounted) setState(() => _error = '无法读取登录会话，请重试或使用「导入会话」。');
    } finally {
      _reading = false;
    }
  }

  @override
  void dispose() {
    unawaited(_controller.clearLocalStorage());
    unawaited(_controller.clearCache());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('登录 Pixiv'),
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: () => _controller.reload(),
          icon: const Icon(Icons.refresh),
        ),
        TextButton(onPressed: _checkLogin, child: const Text('已完成登录')),
      ],
    ),
    body: Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Text(
            widget.rememberSession
                ? '在 Pixiv 官方页面登录。会话将加密保存在此设备，最长 30 天。Shiori 不保存账号密码。'
                : '在 Pixiv 官方页面登录。会话默认仅保留在内存。Android 可在会话菜单开启安全保存。',
            style: const TextStyle(fontSize: 12),
          ),
        ),
        if (_error != null)
          MaterialBanner(
            content: Text(_error!),
            actions: [
              TextButton(
                onPressed: () {
                  setState(() => _error = null);
                  _controller.reload();
                },
                child: const Text('刷新'),
              ),
            ],
          ),
        Expanded(child: WebViewWidget(controller: _controller)),
      ],
    ),
  );
}
