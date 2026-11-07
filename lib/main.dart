import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'core/exporter.dart';
import 'core/models.dart';
import 'core/novel_text.dart';
import 'core/pixiv_client.dart';
import 'platform/platform_bridge.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ShioriApp());
}

const ink = Color(0xff243b36);
const accent = Color(0xff1f6a53);
const paper = Color(0xfff6f7f3);
const muted = Color(0xff6e7d75);
const line = Color(0xffe1e7de);

class ShioriApp extends StatelessWidget {
  const ShioriApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Shiori · 栞',
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'NotoSansSC',
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        primary: accent,
        surface: Colors.white,
        onSurface: ink,
      ),
      scaffoldBackgroundColor: paper,
      textTheme: const TextTheme(
        bodyMedium: TextStyle(height: 1.65),
        bodySmall: TextStyle(color: muted, height: 1.6),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: line),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      dividerColor: line,
    ),
    home: const ExtractorPage(),
  );
}

class ExtractorPage extends StatefulWidget {
  const ExtractorPage({super.key});
  @override
  State<ExtractorPage> createState() => _ExtractorPageState();
}

class _ExtractorPageState extends State<ExtractorPage> {
  final _bridge = PlatformBridge();
  late final PixivClient _api;
  final _link = TextEditingController();
  final _range = TextEditingController();
  final _filename = TextEditingController();
  final _filter = TextEditingController();
  Work? _work;
  Set<String> _selected = {};
  ExportFormat _format = ExportFormat.txt;
  bool _metadata = true, _descriptions = false;
  bool _busy = false, _loggingIn = false, _ready = false;
  double _fontSize = 12;
  String? _error, _notice;
  String _stage = '';
  double? _progress;
  Cancellation? _cancellation;
  ExportFile? _lastFile;

  @override
  void initState() {
    super.initState();
    _api = PixivClient(_bridge.client);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _bridge.init();
      _api.setSession(_bridge.activeSession);
      if (mounted) {
        setState(() {
          _ready = true;
          _notice = _bridge.startupNotice;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    _api.dispose();
    _bridge.dispose();
    for (final c in [_link, _range, _filename, _filter]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _mobile =>
      !kIsWeb &&
      {
        TargetPlatform.android,
        TargetPlatform.iOS,
      }.contains(defaultTargetPlatform);

  Future<bool> _signIn() async {
    if (_loggingIn || !_ready) return false;
    setState(() {
      _loggingIn = true;
      _error = null;
    });
    BuildContext? dialogContext;
    if (!_mobile) {
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) {
            dialogContext = ctx;
            return PopScope(
              canPop: false,
              child: AlertDialog(
                title: const Text('在浏览器中登录'),
                content: const SizedBox(
                  width: 430,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LinearProgressIndicator(),
                      SizedBox(height: 20),
                      Text(
                        '已打开本机连接页。使用配套 Shiori Bridge 扩展连接，在 Pixiv 官方网站登录，然后确认将会话传给本机。',
                      ),
                      SizedBox(height: 12),
                      Text(
                        '不保存账号密码。会话仅在本机使用，安全保存由会话菜单设置决定。此连接将在 5 分钟后失效。',
                        style: TextStyle(color: muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () async {
                      await _bridge.cancelLogin();
                    },
                    child: const Text('取消登录'),
                  ),
                ],
              ),
            );
          },
        ),
      );
    }
    try {
      final session = await _bridge.login(context);
      if (!mounted) return false;
      if (session == null) {
        setState(() => _notice = '登录已取消或等待超时。');
        return false;
      }
      _api.setSession(session);
      try {
        await _bridge.importSession(session);
      } finally {
        _api.setSession(_bridge.activeSession);
      }
      if (mounted) setState(() => _notice = '会话已连接。可继续提取账号有权阅读的小说。');
      return true;
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
      return false;
    } finally {
      if (dialogContext?.mounted == true) Navigator.of(dialogContext!).pop();
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<T> _withLogin<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on LoginRequired {
      _api.setSession(null);
      await _bridge.invalidateSession();
      if (!mounted || !await _signIn()) throw const Cancelled();
      _cancellation?.check();
      return action(); // Retry once; never loop on an inaccessible work.
    }
  }

  Future<void> _importSession() async {
    final input = TextEditingController();
    final session = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入 Pixiv 会话'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '备用方式：在已登录 Pixiv 的浏览器开发者工具 → Application / Storage → Cookies 中，复制 PHPSESSID 的值。',
              ),
              const SizedBox(height: 12),
              Text(
                _bridge.rememberSession
                    ? '该值具有账号访问权限，请勿分享。已开启此设备加密保存，最长 30 天；退出登录将清除。'
                    : '该值具有账号访问权限，请勿分享。默认仅保留在内存，关闭应用后清除。',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: input,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'PHPSESSID',
                  hintText: '仅粘贴 Cookie 的值',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, input.text.trim()),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    // Dialog route may still be animating; dispose after it has unmounted.
    Future<void>.delayed(const Duration(seconds: 1), input.dispose);
    if (session == null || !mounted) return;
    try {
      _api.setSession(session);
      try {
        await _bridge.importSession(session);
      } finally {
        _api.setSession(_bridge.activeSession);
      }
      if (mounted) {
        setState(() {
          _error = null;
          _notice = '会话已导入，将在下一次请求时验证。';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _logout() async {
    _api.setSession(null);
    setState(() {
      _loggingIn = true;
      _work = null;
      _selected = {};
      _lastFile = null;
      _error = null;
    });
    try {
      await _bridge.logout();
      if (mounted) {
        setState(() {
          _notice = '已清除登录会话、安全保存的数据及正文缓存。';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<void> _toggleRememberSession() async {
    final enabled = !_bridge.rememberSession;
    if (enabled) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('在此设备安全保存登录'),
          content: const Text(
            '只保存 Pixiv 登录会话，不保存账号密码。会话会加密保存在此设备，最长 30 天；'
            '下次打开应用自动恢复。可使用此设备的人也可能使用已保存的登录状态。'
            '\n\n关闭此选项或退出登录会删除保存的会话。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('开启安全保存'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _loggingIn = true);
    try {
      await _bridge.setRememberSession(enabled);
      if (mounted) {
        setState(() {
          _error = null;
          _notice = enabled
              ? (_bridge.loggedIn ? '当前会话已加密保存。' : '已开启，下一次登录后将加密保存会话。')
              : '已删除安全保存的会话。本次登录仅保留在内存。';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<void> _load() async {
    if (_busy || !_ready) return;
    final cancel = Cancellation();
    _cancellation = cancel;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
      _stage = '正在读取作品与目录…';
      _progress = null;
    });
    try {
      final link = WorkLink.parse(_link.text);
      final work = await _withLogin(() => _api.load(link, cancel: cancel));
      cancel.check();
      if (mounted) {
        setState(() {
          _work = work;
          _selected = work.chapters
              .where((c) => c.available)
              .map((c) => c.id)
              .toSet();
          _filename.text = work.title;
          _range.clear();
          _filter.clear();
          _lastFile = null;
        });
      }
    } on Cancelled {
      if (mounted) setState(() => _notice = '读取已取消。');
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is FormatException ? e.message : e.toString(),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _export() async {
    final work = _work;
    if (_busy || work == null || _selected.isEmpty) return;
    final cancel = Cancellation();
    _cancellation = cancel;
    final selection = Set<String>.of(_selected);
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
      _stage = '正在提取正文…';
      _progress = 0;
      _lastFile = null;
    });
    try {
      final novels = await _withLogin(
        () => _api.extract(
          work,
          selection,
          cancel: cancel,
          onProgress: (done, total) {
            if (mounted) {
              setState(() {
                _progress = done / total;
                _stage = '正在提取正文 · $done / $total';
              });
            }
          },
        ),
      );
      cancel.check();
      if (mounted) {
        setState(() {
          _stage = '正在生成 ${_format.name.toUpperCase()}…';
          _progress = null;
        });
      }
      final file = await NovelExporter().export(
        _filename.text.trim().isEmpty ? work.title : _filename.text.trim(),
        novels,
        ExportOptions(
          format: _format,
          metadata: _metadata,
          descriptions: _descriptions,
          fontSize: _fontSize,
        ),
      );
      cancel.check();
      if (!mounted) return;
      _lastFile = file;
      final box = context.findRenderObject() as RenderBox?;
      final origin = box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size;
      final saved = await _bridge.save(file, shareOrigin: origin);
      if (mounted) {
        setState(
          () => _notice = saved
              ? '已生成 ${file.name} · ${novels.length} 篇，已交给系统保存。'
              : '文件已生成，保存已取消。可点击「再次保存」。',
        );
      }
    } on Cancelled {
      if (mounted) setState(() => _notice = '提取已取消，未保存不完整的文件。');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  void _applyRange() {
    try {
      final selection = parseSelection(_range.text, _work!.chapters);
      if (_work!.chapters.any(
        (c) => selection.contains(c.id) && !c.available,
      )) {
        throw const FormatException('此范围包含不可访问的章节，请调整后重试。');
      }
      setState(() {
        _selected = selection;
        _error = null;
      });
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _preview(Chapter chapter) async {
    if (_busy) return;
    final cancel = Cancellation();
    _cancellation = cancel;
    setState(() {
      _busy = true;
      _stage = '正在读取预览…';
      _error = null;
    });
    try {
      final novel = await _withLogin(
        () => _api.novel(chapter.id, cancel: cancel),
      );
      cancel.check();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760, maxHeight: 720),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          novel.title,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭预览',
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  Text(novel.author, style: const TextStyle(color: muted)),
                  const Divider(height: 32),
                  Expanded(
                    child: SingleChildScrollView(
                      child: SelectableText(
                        novelText(novel.content),
                        style: const TextStyle(fontSize: 15, height: 1.9),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } on Cancelled {
      /* Cancelled login. */
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _about() => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('关于 Shiori · 栞'),
      content: const SizedBox(
        width: 460,
        child: Text(
          '为喜爱的文字，留一枚书签。\n\nShiori 1.1.0 · 使用 Flutter 构建。\n'
          '支持单篇与系列小说提取，选择章节后按原始顺序合并为 TXT 或 PDF。\n\n'
          '只提取你有权阅读的作品。不可访问、已删除或受限的章节不会被绕过。'
          '插图保留为原文链接或占位文字。\n\n'
          '默认仅在内存保留会话。可选择通过系统安全存储保存登录，最长 30 天。'
          '不使用第三方转发服务。退出会话会删除保存的登录信息并清除缓存；'
          '导出的文件由你自行管理。\n\n'
          'FreeBSD 使用 Flutter Web 与仅监听本机的 Python 服务。',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('知道了'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = constraints.maxWidth >= 1120;
      return Scaffold(
        body: SafeArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (desktop) _sidebar(),
              Expanded(
                child: Column(
                  children: [
                    _header(desktop),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.all(desktop ? 36 : 20),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1340),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '你的故事，随处可读。',
                                  style: TextStyle(
                                    fontSize: 30,
                                    height: 1.4,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: -0.6,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                const Text(
                                  '从 Pixiv 收藏一段文字，整理成属于自己的阅读文件。',
                                  style: TextStyle(color: muted, fontSize: 14),
                                ),
                                const SizedBox(height: 28),
                                _sourceCard(),
                                if (_error != null) _banner(_error!, true),
                                if (_notice != null) _banner(_notice!, false),
                                if (_busy)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 18),
                                    child: _operation(),
                                  ),
                                const SizedBox(height: 24),
                                if (desktop)
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: _work == null
                                            ? _empty()
                                            : _chapters(),
                                      ),
                                      const SizedBox(width: 24),
                                      SizedBox(
                                        width: 310,
                                        child: _exportPanel(),
                                      ),
                                    ],
                                  )
                                else ...[
                                  _work == null ? _empty() : _chapters(),
                                  const SizedBox(height: 20),
                                  _exportPanel(),
                                ],
                                const SizedBox(height: 28),
                                const Text(
                                  '仅用于个人阅读与备份 · 请尊重作者的版权及作品使用约定',
                                  style: TextStyle(fontSize: 11, color: muted),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _sidebar() => Container(
    width: 210,
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(right: BorderSide(color: line)),
    ),
    padding: const EdgeInsets.fromLTRB(22, 30, 22, 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _brand(),
        const SizedBox(height: 58),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xffeaf1e9),
            borderRadius: BorderRadius.circular(9),
          ),
          child: const Row(
            children: [
              Icon(Icons.auto_stories_outlined, color: accent, size: 20),
              SizedBox(width: 12),
              Text(
                '小说提取',
                style: TextStyle(color: accent, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: _about,
          icon: const Icon(Icons.info_outline, size: 19),
          label: const Text('使用说明'),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: paper,
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.spa_outlined, color: accent, size: 24),
              SizedBox(height: 10),
              Text(
                '让文字，慢下来。',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 6),
              Text(
                '一份文件，一段安静的\n离线阅读时光。',
                style: TextStyle(fontSize: 11, color: muted, height: 1.8),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'SHIORI  /  v1.0.0',
          style: TextStyle(fontSize: 10, letterSpacing: 1.5, color: muted),
        ),
      ],
    ),
  );

  Widget _brand() => SizedBox(
    width: 165,
    child: Row(
      children: [
        Container(
          width: 37,
          height: 42,
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(
            Icons.bookmark_border_rounded,
            color: Colors.white,
            size: 25,
          ),
        ),
        const SizedBox(width: 11),
        const Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Shiori 栞',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
                ),
                Text(
                  'PIXIV NOVEL KEEPER',
                  style: TextStyle(
                    fontSize: 8,
                    color: muted,
                    letterSpacing: 1.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _header(bool desktop) => Container(
    height: 76,
    padding: EdgeInsets.symmetric(horizontal: desktop ? 36 : 16),
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(bottom: BorderSide(color: line)),
    ),
    child: Row(
      children: [
        if (desktop)
          const Text(
            '工作台  /  小说提取',
            style: TextStyle(fontSize: 12, color: muted),
          )
        else
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: _brand()),
          ),
        if (desktop) const Spacer(),
        if (_bridge.loggedIn) ...[
          const Icon(Icons.check_circle, size: 15, color: accent),
          const SizedBox(width: 7),
          Text(
            _bridge.rememberSession ? '登录已安全保存' : '已连接',
            style: const TextStyle(fontSize: 12),
          ),
        ] else
          TextButton.icon(
            onPressed: _busy || _loggingIn || !_ready ? null : _signIn,
            icon: const Icon(Icons.person_outline, size: 18),
            label: const Text('登录 Pixiv'),
          ),
        PopupMenuButton<String>(
          tooltip: '会话与帮助',
          onSelected: (v) {
            if (v == 'import') {
              unawaited(_importSession());
            }
            if (v == 'logout') {
              unawaited(_logout());
            }
            if (v == 'remember') {
              unawaited(_toggleRememberSession());
            }
            if (v == 'help') _about();
          },
          itemBuilder: (_) => [
            if (_bridge.supportsSessionStorage)
              CheckedPopupMenuItem(
                value: 'remember',
                checked: _bridge.rememberSession,
                enabled: !_busy && !_loggingIn && _ready,
                child: const Text('在此设备安全保存登录'),
              ),
            PopupMenuItem(
              value: 'import',
              enabled: !_busy && !_loggingIn && _ready,
              child: const Text('导入会话（备用）'),
            ),
            PopupMenuItem(
              value: 'logout',
              enabled: !_busy && !_loggingIn && _bridge.loggedIn,
              child: const Text('退出并清除会话'),
            ),
            const PopupMenuItem(value: 'help', child: Text('关于与使用说明')),
          ],
        ),
      ],
    ),
  );

  Widget _card(Widget child, {EdgeInsets padding = const EdgeInsets.all(24)}) =>
      Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: line),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Material(color: Colors.transparent, child: child),
      );

  Widget _sourceCard() => _card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            _Step('01'),
            SizedBox(width: 10),
            Text(
              '添加作品',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
          ],
        ),
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (context, c) {
            final field = TextField(
              controller: _link,
              enabled: !_busy && _ready,
              onSubmitted: (_) => _load(),
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                hintText: '粘贴 Pixiv 小说或系列链接',
                prefixIcon: Icon(Icons.link, size: 21),
              ),
            );
            final button = FilledButton.icon(
              onPressed: _busy || !_ready ? null : _load,
              icon: const Icon(Icons.arrow_forward, size: 18),
              label: const Text('读取作品'),
            );
            return c.maxWidth < 500
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [field, const SizedBox(height: 12), button],
                  )
                : Row(
                    children: [
                      Expanded(child: field),
                      const SizedBox(width: 12),
                      button,
                    ],
                  );
          },
        ),
        const SizedBox(height: 12),
        const Text(
          '支持 novel/show.php?id=…、novel/series/… 或小说 ID。需要登录时会自动打开登录流程。',
          style: TextStyle(fontSize: 11, color: muted),
        ),
      ],
    ),
  );

  Widget _empty() => _card(
    Column(
      children: [
        const SizedBox(height: 30),
        Container(
          width: 84,
          height: 84,
          decoration: const BoxDecoration(
            color: Color(0xffedf2e8),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.menu_book_rounded, size: 39, color: accent),
        ),
        const SizedBox(height: 24),
        const Text(
          '下一段故事，从这里开始',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 10),
        const Text(
          '添加作品后，在这里选择想要保存的章节。\n单篇或整个系列，都能轻松整理。',
          textAlign: TextAlign.center,
          style: TextStyle(color: muted, fontSize: 13, height: 1.9),
        ),
        const SizedBox(height: 34),
        const Wrap(
          spacing: 22,
          runSpacing: 12,
          alignment: WrapAlignment.center,
          children: [
            _Feature(Icons.checklist, '按需选章'),
            _Feature(Icons.merge_type, '合并成册'),
            _Feature(Icons.offline_pin_outlined, '离线阅读'),
          ],
        ),
        const SizedBox(height: 30),
      ],
    ),
  );

  Widget _chapters() {
    final work = _work!;
    final query = _filter.text.trim().toLowerCase();
    final chapters = work.chapters
        .where(
          (c) => c.title.toLowerCase().contains(query) || '${c.order}' == query,
        )
        .toList();
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _Step('02'),
              const SizedBox(width: 10),
              const Text(
                '选择章节',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
              ),
              const Spacer(),
              _tag('${work.chapters.length} 篇'),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            work.title,
            style: const TextStyle(
              fontSize: 23,
              fontWeight: FontWeight.w600,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${work.author}  ·  ${work.link.kind == WorkKind.series ? '系列小说' : '单篇小说'}',
            style: const TextStyle(color: muted, fontSize: 12),
          ),
          if (work.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                plainDescription(work.description),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            ),
          const Divider(height: 36),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(
                        () => _selected = work.chapters
                            .where((c) => c.available)
                            .map((c) => c.id)
                            .toSet(),
                      ),
                child: const Text('全选'),
              ),
              TextButton(
                onPressed: _busy ? null : () => setState(() => _selected = {}),
                child: const Text('清空'),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(
                        () => _selected = work.chapters
                            .where(
                              (c) => c.available && !_selected.contains(c.id),
                            )
                            .map((c) => c.id)
                            .toSet(),
                      ),
                child: const Text('反选'),
              ),
              Text(
                '已选 ${_selected.length} / ${work.chapters.length}',
                style: const TextStyle(fontSize: 12, color: muted),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _range,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    hintText: '范围，如 1-5, 8, 10-12',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _applyRange(),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _busy ? null : _applyRange,
                child: const Text('应用'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _filter,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: '筛选章节标题（不影响已选章节）',
              prefixIcon: Icon(Icons.search, size: 18),
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            color: paper,
            child: const Row(
              children: [
                SizedBox(width: 42),
                Expanded(
                  child: Text(
                    '章节 / 按系列顺序排列',
                    style: TextStyle(fontSize: 11, color: muted),
                  ),
                ),
                Text('预览', style: TextStyle(fontSize: 11, color: muted)),
              ],
            ),
          ),
          if (chapters.isEmpty)
            const Padding(padding: EdgeInsets.all(30), child: Text('没有匹配的章节。')),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 520),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: chapters.length,
              itemBuilder: (context, i) {
                final c = chapters[i];
                return Container(
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: line)),
                  ),
                  child: Row(
                    children: [
                      Checkbox(
                        value: _selected.contains(c.id),
                        onChanged: _busy || !c.available
                            ? null
                            : (v) => setState(() {
                                if (v == true) {
                                  _selected.add(c.id);
                                } else {
                                  _selected.remove(c.id);
                                }
                              }),
                      ),
                      SizedBox(
                        width: 34,
                        child: Text(
                          '${c.order}'.padLeft(2, '0'),
                          style: const TextStyle(fontSize: 11, color: muted),
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Text(
                            c.title,
                            style: TextStyle(
                              fontSize: 13,
                              color: c.available ? ink : muted,
                            ),
                          ),
                        ),
                      ),
                      if (!c.available)
                        const Padding(
                          padding: EdgeInsets.all(8),
                          child: Tooltip(
                            message: '不可访问',
                            child: Icon(
                              Icons.lock_outline,
                              size: 16,
                              color: muted,
                            ),
                          ),
                        ),
                      IconButton(
                        tooltip: '预览正文',
                        onPressed: _busy || !c.available
                            ? null
                            : () => _preview(c),
                        icon: const Icon(Icons.article_outlined, size: 18),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _exportPanel() => _card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            _Step('03'),
            SizedBox(width: 10),
            Text(
              '导出设置',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const Text('文件格式', style: TextStyle(fontSize: 12, color: muted)),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _formatOption(
                ExportFormat.txt,
                'TXT',
                '轻盈 · 纯文本',
                Icons.notes,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _formatOption(
                ExportFormat.pdf,
                'PDF',
                '排版 · 适合打印',
                Icons.picture_as_pdf_outlined,
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const Text('文件名称', style: TextStyle(fontSize: 12, color: muted)),
        const SizedBox(height: 10),
        TextField(
          controller: _filename,
          enabled: !_busy && _work != null,
          decoration: InputDecoration(
            hintText: '使用作品标题',
            suffixText: '.${_format.name}',
            isDense: true,
          ),
        ),
        const SizedBox(height: 18),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('保留作者与原文链接', style: TextStyle(fontSize: 12)),
          value: _metadata,
          onChanged: _busy ? null : (v) => setState(() => _metadata = v),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('包含作品简介', style: TextStyle(fontSize: 12)),
          value: _descriptions,
          onChanged: _busy ? null : (v) => setState(() => _descriptions = v),
        ),
        if (_format == ExportFormat.pdf) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('正文字号', style: TextStyle(fontSize: 12, color: muted)),
              const Spacer(),
              Text(
                '${_fontSize.round()} pt',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
          Slider(
            min: 10,
            max: 18,
            divisions: 8,
            value: _fontSize,
            onChanged: _busy ? null : (v) => setState(() => _fontSize = v),
          ),
        ],
        const Divider(height: 34),
        Row(
          children: [
            const Text('合并导出', style: TextStyle(fontSize: 12, color: muted)),
            const Spacer(),
            Text(
              '${_selected.length} 篇 → 1 个文件',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _busy || _selected.isEmpty ? null : _export,
            icon: const Icon(Icons.download_outlined, size: 19),
            label: Text('导出 ${_format.name.toUpperCase()}'),
          ),
        ),
        if (_lastFile != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        try {
                          await _bridge.save(_lastFile!);
                        } catch (e) {
                          if (mounted) setState(() => _error = e.toString());
                        }
                      },
                icon: const Icon(Icons.save_alt, size: 17),
                label: const Text('再次保存'),
              ),
            ),
          ),
        const SizedBox(height: 14),
        const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_outline, size: 13, color: muted),
            SizedBox(width: 6),
            Expanded(
              child: Text(
                '在本机生成文件，章节按原始顺序合并。',
                style: TextStyle(fontSize: 10, color: muted, height: 1.8),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _formatOption(
    ExportFormat format,
    String title,
    String subtitle,
    IconData icon,
  ) {
    final selected = _format == format;
    return InkWell(
      onTap: _busy ? null : () => setState(() => _format = format),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xffedf4eb) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? accent : line,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(icon, color: selected ? accent : muted, size: 23),
            const SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: selected ? accent : ink,
              ),
            ),
            const SizedBox(height: 5),
            Text(subtitle, style: const TextStyle(fontSize: 9, color: muted)),
          ],
        ),
      ),
    );
  }

  Widget _tag(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: paper,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(text, style: const TextStyle(fontSize: 10, color: muted)),
  );

  Widget _banner(String message, bool error) => Container(
    margin: const EdgeInsets.only(top: 18),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: error ? const Color(0xfffff0e9) : const Color(0xffeaf2e7),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          error ? Icons.error_outline : Icons.check_circle_outline,
          size: 18,
          color: error ? const Color(0xffa45030) : accent,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: SelectableText(message, style: const TextStyle(fontSize: 12)),
        ),
        InkWell(
          onTap: () => setState(() {
            if (error) {
              _error = null;
            } else {
              _notice = null;
            }
          }),
          child: const Icon(Icons.close, size: 16, color: muted),
        ),
      ],
    ),
  );

  Widget _operation() => _card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(_stage, style: const TextStyle(fontSize: 12))),
            TextButton(
              onPressed: () {
                _cancellation?.cancel();
                if (_loggingIn) {
                  unawaited(_bridge.cancelLogin());
                }
              },
              child: const Text('取消'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: _progress,
          minHeight: 4,
          borderRadius: BorderRadius.circular(4),
        ),
      ],
    ),
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
  );
}

class _Step extends StatelessWidget {
  const _Step(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    width: 25,
    height: 25,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: const Color(0xffeef2e9),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: accent,
        fontSize: 10,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _Feature extends StatelessWidget {
  const _Feature(this.icon, this.label);
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 16, color: accent),
      const SizedBox(width: 7),
      Text(label, style: const TextStyle(fontSize: 11, color: muted)),
    ],
  );
}
