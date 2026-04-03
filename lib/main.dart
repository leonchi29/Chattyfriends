import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ChattyFriendsApp());
}

class ChattyFriendsApp extends StatelessWidget {
  const ChattyFriendsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ChattyFriends',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B66C9)),
        useMaterial3: true,
      ),
      home: const ChattyWebShellPage(),
    );
  }
}

class ChattyWebShellPage extends StatefulWidget {
  const ChattyWebShellPage({super.key});

  @override
  State<ChattyWebShellPage> createState() => _ChattyWebShellPageState();
}

class _ChattyWebShellPageState extends State<ChattyWebShellPage> {
  static const String _chatUrl = 'https://chatty-friends-51890.web.app';

  late final WebViewController _controller;
  bool _isLoading = true;
  int _loadingProgress = 0;
  Timer? _loadTimeout;
  String? _fatalError;

  @override
  void dispose() {
    _loadTimeout?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _requestCorePermissions();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _isLoading = true;
            });
          },
          onProgress: (value) {
            if (!mounted) return;
            setState(() {
              _loadingProgress = value;
            });
          },
          onPageFinished: (_) {
            if (!mounted) return;
            _loadTimeout?.cancel();
            setState(() {
              _isLoading = false;
              _loadingProgress = 100;
              _fatalError = null;
            });
          },
          onWebResourceError: (e) {
            if (!mounted) return;
            setState(() {
              _isLoading = false;
              _fatalError = 'No se pudo cargar ChattyFriends (${e.errorCode}).';
            });
          },
        ),
      )
      ..loadRequest(Uri.parse(_chatUrl));

    _startLoadWatchdog();

    final platformController = _controller.platform;
    if (platformController is AndroidWebViewController) {
      platformController.setMediaPlaybackRequiresUserGesture(false);
      platformController.setOnPlatformPermissionRequest((request) {
        request.grant();
      });
    }
  }

  Future<void> _reload() async {
    setState(() {
      _isLoading = true;
      _loadingProgress = 0;
      _fatalError = null;
    });
    _startLoadWatchdog();
    await _controller.reload();
  }

  void _startLoadWatchdog() {
    _loadTimeout?.cancel();
    _loadTimeout = Timer(const Duration(seconds: 18), () {
      if (!mounted || !_isLoading) return;
      setState(() {
        _isLoading = false;
        _fatalError = 'La app tardo demasiado en iniciar.';
      });
    });
  }

  Future<void> _openInSystemBrowser() async {
    try {
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', _chatUrl]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [_chatUrl]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [_chatUrl]);
      }
    } catch (_) {}
  }

  Future<void> _requestCorePermissions() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    try {
      await [
        Permission.microphone,
        Permission.camera,
        Permission.photos,
      ].request();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          if (_fatalError == null) WebViewWidget(controller: _controller),
          if (_isLoading)
            LinearProgressIndicator(
              minHeight: 2,
              value: _loadingProgress > 0 && _loadingProgress < 100
                  ? _loadingProgress / 100
                  : null,
            ),
          if (_fatalError != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline, size: 34, color: Color(0xFFC62828)),
                          const SizedBox(height: 10),
                          Text(
                            _fatalError!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 10),
                          if (Platform.isWindows)
                            const Text(
                              'En Windows verifica tener instalado Microsoft Edge WebView2 Runtime.',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12, color: Colors.black54),
                            ),
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            alignment: WrapAlignment.center,
                            children: [
                              FilledButton(
                                onPressed: _reload,
                                child: const Text('Reintentar'),
                              ),
                              OutlinedButton(
                                onPressed: _openInSystemBrowser,
                                child: const Text('Abrir en navegador'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
