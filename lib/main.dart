import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';

import 'firebase_options.dart';

const kWebBaseUrl = 'https://geonganghaegym.junghaebom.com';

// 백그라운드 설정 코드는 맨 최상단에 위치해야함
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('Handling a background message ${message.messageId}');
}

final storage = FlutterSecureStorage(); // Secure Storage 인스턴스 생성

/// 웹뷰 로딩과 병렬로 도는 네이티브 초기화. FCM을 쓰는 곳은 이걸 기다린다.
late final Future<void> nativeInit;

/// 스플래시가 내려가면 완료된다. 스플래시 위에 시스템 권한 팝업이 뜨면(iOS) 스플래시가 팝업에 답할 때까지
/// 내려가지 않으므로, 권한 요청은 이걸 기다린 뒤에 한다.
final splashRemoved = Completer<void>();

Future<void> main() async {
  // 첫 페이지 로딩이 끝날 때까지 네이티브 스플래시를 유지한다(흰 웹뷰가 보이지 않게).
  FlutterNativeSplash.preserve(
      widgetsBinding: WidgetsFlutterBinding.ensureInitialized());

  if (!kIsWeb &&
      kDebugMode &&
      defaultTargetPlatform == TargetPlatform.android) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(kDebugMode);
  }

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // 권한 팝업에 답할 때까지 웹뷰가 뜨지 않던 문제 — 화면부터 띄우고 초기화는 뒤에서 한다.
  runApp(const MaterialApp(home: MyApp()));
  nativeInit = _initNative();
}

Future<void> _initNative() async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      name: "건강해짐",
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }

  await splashRemoved.future;

  // 권한 요청은 동시에 띄우면 충돌하므로 순서대로 한다.
  await Permission.camera.request();

  await fcmSetting();
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

Future<void> fcmSetting() async {
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  FirebaseMessaging messaging = FirebaseMessaging.instance;

  await messaging.setForegroundNotificationPresentationOptions(
    alert: true,
    badge: true,
    sound: true,
  );

  NotificationSettings settings = await messaging.requestPermission(
    alert: true,
    announcement: false,
    badge: true,
    carPlay: false,
    criticalAlert: false,
    provisional: false,
    sound: true,
  );

  debugPrint('User granted permission: ${settings.authorizationStatus}');

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'high_importance_channel', // id
      'High Importance Notifications',
      description: 'This channel is used for important notifications.',
      importance: Importance.high,
      playSound: true);

  var initialzationSettingsIOS = const DarwinInitializationSettings(
    requestSoundPermission: true,
    requestBadgePermission: true,
    requestAlertPermission: true,
  );

  var initializationSettingsAndroid =
      const AndroidInitializationSettings('@mipmap/launcher_icon');

  var initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid, iOS: initialzationSettingsIOS);
  final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await flutterLocalNotificationsPlugin.initialize(
    settings: initializationSettings,
  );

  FirebaseMessaging.onMessage.listen(
    (RemoteMessage message) {
      debugPrint('Got a message whilst in the foreground!');
      debugPrint('Message data: ${message.data}');

      RemoteNotification? notification = message.notification;
      AndroidNotification? android = message.notification?.android;

      if (message.notification != null && android != null) {
        flutterLocalNotificationsPlugin.show(
          id: notification.hashCode,
          title: notification?.title,
          body: notification?.body,
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              channel.id,
              channel.name,
              icon: '@mipmap/launcher_icon',
            ),
          ),
        );
      }
    },
  );

  // 토큰 리프레시 수신
  FirebaseMessaging.instance.onTokenRefresh.listen(
    (newToken) async {
      String? memberId = await storage.read(key: 'memberId');
      if (memberId != null) {
        await sendTokenToServer(int.parse(memberId), newToken);
      }
    },
  );
}

class _MyAppState extends State<MyApp> {
  final GlobalKey webViewKey = GlobalKey();
  InAppWebViewController? _webViewController;
  DateTime? _lastBackPressed;
  bool _splashRemoved = false;

  @override
  void initState() {
    super.initState();
    // 네트워크가 느리거나 끊겨도 스플래시에 갇히지 않게 상한을 둔다.
    Future.delayed(const Duration(seconds: 5), _removeSplash);
  }

  void _removeSplash() {
    if (_splashRemoved) return;
    _splashRemoved = true;
    FlutterNativeSplash.remove();
    splashRemoved.complete();
  }

  /// 웹뷰 히스토리가 남아 있으면 웹뷰 안에서 뒤로 이동하고,
  /// 더 이상 뒤로 갈 곳이 없으면 2초 안에 두 번 눌러야 앱을 종료한다.
  Future<void> _handleBack() async {
    final controller = _webViewController;
    if (controller != null && await controller.canGoBack()) {
      await controller.goBack();
      return;
    }

    final now = DateTime.now();
    if (_lastBackPressed == null ||
        now.difference(_lastBackPressed!) > const Duration(seconds: 2)) {
      _lastBackPressed = now;
      Fluttertoast.showToast(
          msg: '한 번 더 누르면 앱이 종료됩니다.',
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
          backgroundColor: Colors.black,
          textColor: Colors.white,
          fontSize: 16.0);
      return;
    }

    await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    // canPop: false — 뒤로가기를 항상 가로채 _handleBack에서 직접 처리한다.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBack();
      },
      // Scaffold가 SafeArea 바깥에 있어야 상태바 영역까지 배경색이 칠해진다(안쪽이면 검은 띠).
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: InAppWebView(
            key: webViewKey,
            initialUrlRequest: URLRequest(
              url: WebUri("$kWebBaseUrl/"),
            ),
            initialSettings: InAppWebViewSettings(
              allowsBackForwardNavigationGestures: true,
              javaScriptEnabled: true,
              javaScriptCanOpenWindowsAutomatically: true,
            ),
            onLoadStop: (controller, url) {
              _removeSplash();
              shareTokenWithWeb(controller, url);
            },
            onReceivedError: (controller, request, error) {
              if (request.isForMainFrame ?? true) _removeSplash();
            },
            onWebViewCreated: (controller) {
              _webViewController = controller;
              controller.addJavaScriptHandler(
                handlerName: 'Channel',
                callback: (args) async {
                  // 로그인 성공 시 FCM 토큰 발급 및 백엔드로 전송
                  int memberId = args[0];
                  await nativeInit;
                  await storage.write(
                      key: 'memberId', value: memberId.toString());
                  String? fcmToken =
                      await FirebaseMessaging.instance.getToken();
                  if (fcmToken != null) {
                    await sendTokenToServer(memberId, fcmToken);
                  }
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 웹 로그아웃이 이 기기 토큰만 지우도록, 웹이 로그아웃 때 읽는 localStorage 키에 FCM 토큰을 넣어 둔다.
/// 페이지를 로드할 때마다 넣으므로 토큰이 갱신돼도 다음 로드부터 맞춰진다.
Future<void> shareTokenWithWeb(
    InAppWebViewController controller, WebUri? url) async {
  // 소셜 로그인 등 외부 페이지의 localStorage에는 토큰을 남기지 않는다.
  if (url?.host != Uri.parse(kWebBaseUrl).host) return;
  try {
    await nativeInit;
    final fcmToken = await FirebaseMessaging.instance.getToken();
    if (fcmToken == null) return;
    await controller.evaluateJavascript(
      source:
          "localStorage.setItem('serviceWorkerRegistration', ${jsonEncode(fcmToken)});",
    );
  } catch (e) {
    debugPrint('웹에 FCM 토큰 전달 실패: $e');
  }
}

Future<void> sendTokenToServer(int memberId, String fcmToken) async {
  debugPrint('memberId => $memberId');
  debugPrint('fcmToken => $fcmToken');
  String deviceType = Platform.isIOS ? 'IOS' : 'AOS'; // 플랫폼 타입 결정
  final response = await http.post(
    Uri.parse('$kWebBaseUrl/api/v1/push/webview'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(
      {'memberId': memberId, 'token': fcmToken, 'deviceType': deviceType},
    ),
  );

  if (response.statusCode == 200) {
    debugPrint('Token saved successfully');
  } else {
    debugPrint('Failed to save token');
  }
}
