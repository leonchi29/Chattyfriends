import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'firebase_options.dart';

const String kSupabaseUrl = 'https://xijruxarvehmlvzbnffn.supabase.co';
const String kSupabaseAnon =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhpanJ1eGFydmVobWx2emJuZmZuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI2NTIyMjgsImV4cCI6MjA4ODIyODIyOH0.CvoIzfgzZLkCa9Tuix4U4sP0fp1oJjEwjn-Yuczo3Yk';

final FlutterLocalNotificationsPlugin _localNotifications =
    FlutterLocalNotificationsPlugin();
final StreamController<Map<String, dynamic>> _notificationActions =
    StreamController<Map<String, dynamic>>.broadcast();

bool _notifInitialized = false;

Future<void> _handleNotificationResponse(NotificationResponse response) async {
  final payload = response.payload;
  if (payload == null || payload.isEmpty) return;
  try {
    final map = jsonDecode(payload) as Map<String, dynamic>;
    map['actionId'] = response.actionId ?? '';
    _notificationActions.add(map);
  } catch (_) {}
}

Future<void> _ensureNotificationsInitialized() async {
  if (_notifInitialized) return;
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const darwinInit = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
    notificationCategories: [
      DarwinNotificationCategory(
        'incoming_call',
        actions: [
          DarwinNotificationAction.plain(
            'accept',
            'Aceptar',
            options: {DarwinNotificationActionOption.foreground},
          ),
          DarwinNotificationAction.plain(
            'reject',
            'Rechazar',
            options: {DarwinNotificationActionOption.destructive},
          ),
        ],
      ),
    ],
  );
  const initSettings = InitializationSettings(
    android: androidInit,
    iOS: darwinInit,
  );
  await _localNotifications.initialize(
    initSettings,
    onDidReceiveNotificationResponse: _handleNotificationResponse,
    onDidReceiveBackgroundNotificationResponse: _handleNotificationResponse,
  );
  _notifInitialized = true;
}

Future<void> _showPushNotification(Map<String, dynamic> data) async {
  await _ensureNotificationsInitialized();
  final kind = (data['kind'] ?? data['event'] ?? 'message').toString();
  final title = (data['title'] ?? 'ChattyFriends').toString();
  final body = (data['body'] ?? '').toString();

  final actions = <AndroidNotificationAction>[];
  if (kind == 'call-incoming' || kind == 'gcall-incoming') {
    actions.addAll(const [
      AndroidNotificationAction('accept', 'Aceptar'),
      AndroidNotificationAction('reject', 'Rechazar'),
    ]);
  }

  final details = NotificationDetails(
    android: AndroidNotificationDetails(
      'chatty_events',
      'ChattyFriends Eventos',
      channelDescription: 'Mensajes nuevos y llamadas entrantes',
      importance: Importance.max,
      priority: Priority.high,
      category: kind == 'call-incoming' || kind == 'gcall-incoming'
          ? AndroidNotificationCategory.call
          : AndroidNotificationCategory.message,
      actions: actions,
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      categoryIdentifier: kind == 'call-incoming' || kind == 'gcall-incoming'
          ? 'incoming_call'
          : null,
    ),
  );

  await _localNotifications.show(
    (data['tag'] ?? '$title:$body').toString().hashCode,
    title,
    body,
    details,
    payload: jsonEncode(data),
  );
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await _showPushNotification(message.data);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await Supabase.initialize(url: kSupabaseUrl, anonKey: kSupabaseAnon);
  await _ensureNotificationsInitialized();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
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

class _ChattyWebShellPageState extends State<ChattyWebShellPage>
    with WidgetsBindingObserver {
  static const String _chatUrlBase = 'https://chatty-friends-51890.web.app/app/';
  static const String _webBuildTag = '20260403-push';

  late final WebViewController _controller;
  late final FirebaseMessaging _messaging;
  late final SupabaseClient _supabase;
  StreamSubscription<Map<String, dynamic>>? _actionSub;
  StreamSubscription<RemoteMessage>? _foregroundSub;
  StreamSubscription<String>? _tokenRefreshSub;
  bool _isLoading = true;
  int _loadingProgress = 0;
  Timer? _loadTimeout;
  String? _fatalError;
  String? _pendingJsAction;
  String? _currentUserId;
  String? _currentUsername;
  String? _fcmToken;
  bool _askingPermissions = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _supabase = Supabase.instance.client;
    _messaging = FirebaseMessaging.instance;

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel(
        'ChattyBridge',
        onMessageReceived: (message) => _handleJsBridgeMessage(message.message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() => _isLoading = true);
          },
          onProgress: (value) {
            if (!mounted) return;
            setState(() => _loadingProgress = value);
          },
          onPageFinished: (_) {
            if (!mounted) return;
            _loadTimeout?.cancel();
            _dispatchPendingJsAction();
            _requestSessionSync();
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
      );

    final platformController = _controller.platform;
    if (platformController is AndroidWebViewController) {
      platformController.setMediaPlaybackRequiresUserGesture(false);
      platformController.setOnPlatformPermissionRequest((request) async {
        await _ensureCorePermissions();
        request.grant();
      });
      platformController.setOnShowFileSelector((params) async {
        final result = await FilePicker.platform.pickFiles(
          allowMultiple: params.mode == FileSelectorMode.openMultiple,
          type: FileType.any,
        );
        if (result == null || result.files.isEmpty) return <String>[];
        return result.files
            .map((f) => f.path)
            .whereType<String>()
            .map((p) => Uri.file(p).toString())
            .toList();
      });
    }
    if (platformController is WebKitWebViewController) {
      platformController.setAllowsInlineMediaPlayback(true);
      platformController.setMediaTypesRequiringUserAction(const <PlaybackMediaTypes>{});
    }

    _startLoadWatchdog();
    _bindNotificationStreams();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initAndLoad();
    });
  }

  void _bindNotificationStreams() {
    _actionSub = _notificationActions.stream.listen(_handleNotificationAction);
    _foregroundSub = FirebaseMessaging.onMessage.listen((message) {
      _showPushNotification(message.data);
    });
    _tokenRefreshSub = _messaging.onTokenRefresh.listen((token) {
      _fcmToken = token;
      _syncDeviceToken();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _ensureCorePermissions();
      _dispatchPendingJsAction();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _loadTimeout?.cancel();
    _actionSub?.cancel();
    _foregroundSub?.cancel();
    _tokenRefreshSub?.cancel();
    super.dispose();
  }

  Future<void> _initAndLoad() async {
    // Carga la pagina de inmediato — permisos y FCM van en paralelo
    unawaited(_ensureCorePermissions());
    unawaited(_initMessaging());
    await _controller.loadRequest(Uri.parse(_chatUrlBase));
  }

  Future<void> _initMessaging() async {
    await _messaging.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      carPlay: false,
      criticalAlert: true,
      provisional: false,
      sound: true,
    );
    _fcmToken = await _messaging.getToken();
    await _syncDeviceToken();
  }

  Future<void> _syncDeviceToken() async {
    final userId = _currentUserId;
    final token = _fcmToken;
    if (userId == null || userId.isEmpty || token == null || token.isEmpty) return;
    try {
      await _supabase.from('device_tokens').upsert({
        'user_id': userId,
        'token': token,
        'platform': Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'other'),
        'username': _currentUsername,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {}
  }

  Future<void> _reload() async {
    setState(() {
      _isLoading = true;
      _loadingProgress = 0;
      _fatalError = null;
    });
    _startLoadWatchdog();
    await _initAndLoad();
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

  Future<void> _ensureCorePermissions() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    if (_askingPermissions) return;
    _askingPermissions = true;
    try {
      await _requestPermissionIfNeeded(Permission.camera);
      await _requestPermissionIfNeeded(Permission.microphone);
      await _requestPermissionIfNeeded(Permission.notification);

      await _messaging.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );
    } catch (_) {}
    _askingPermissions = false;
  }

  Future<void> _requestPermissionIfNeeded(Permission permission) async {
    final status = await permission.status;
    if (status.isGranted) return;
    final updated = await permission.request();
    if (updated.isPermanentlyDenied) {
      await openAppSettings();
    }
  }

  void _requestSessionSync() {
    _controller.runJavaScript(
      'window.chattySyncNativeSession && window.chattySyncNativeSession();',
    );
  }

  void _dispatchPendingJsAction() {
    final action = _pendingJsAction;
    if (action == null || action.isEmpty) return;
    _pendingJsAction = null;
    _controller.runJavaScript(action);
  }

  void _handleJsBridgeMessage(String rawMessage) {
    try {
      final data = jsonDecode(rawMessage) as Map<String, dynamic>;
      final kind = (data['kind'] ?? '').toString();
      if (kind == 'session') {
        final user = (data['user'] ?? {}) as Map<String, dynamic>;
        _currentUserId = (user['id'] ?? '').toString();
        _currentUsername = (user['username'] ?? '').toString();
        _syncDeviceToken();
      } else if (kind == 'logout') {
        _currentUserId = null;
        _currentUsername = null;
      } else if (kind == 'notify') {
        _showPushNotification(data);
      }
    } catch (_) {}
  }

  void _handleNotificationAction(Map<String, dynamic> action) {
    final event = (action['event'] ?? '').toString();
    final actionId = (action['actionId'] ?? '').toString();
    dynamic rawTarget = action['target'];
    Map<String, dynamic> target = <String, dynamic>{};
    if (rawTarget is Map<String, dynamic>) {
      target = rawTarget;
    } else if (rawTarget is String && rawTarget.isNotEmpty) {
      try {
        final parsed = jsonDecode(rawTarget);
        if (parsed is Map<String, dynamic>) target = parsed;
      } catch (_) {}
    }
    final encoded = jsonEncode({
      'event': event,
      'action': actionId,
      'target': target,
    });
    _pendingJsAction =
        'window.chattyHandleNativeAction && window.chattyHandleNativeAction(${jsonEncode(encoded)});';
    _dispatchPendingJsAction();
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
                          const Icon(Icons.error_outline,
                              size: 34, color: Color(0xFFC62828)),
                          const SizedBox(height: 10),
                          Text(
                            _fatalError!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 14),
                          FilledButton(
                            onPressed: _reload,
                            child: const Text('Reintentar'),
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
