import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:flutter/material.dart';
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      name: "건강해짐",
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }

  await Permission.camera.request();

  await fcmSetting();

  if (!kIsWeb &&
      kDebugMode &&
      defaultTargetPlatform == TargetPlatform.android) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(kDebugMode);
  }

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]).then((_) {
    runApp(const MaterialApp(home: MyApp()));
  });
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
      child: SafeArea(
        child: Scaffold(
          body: InAppWebView(
            key: webViewKey,
            initialUrlRequest: URLRequest(
              url: WebUri("$kWebBaseUrl/"),
            ),
            initialSettings: InAppWebViewSettings(
              allowsBackForwardNavigationGestures: true,
              javaScriptEnabled: true,
              javaScriptCanOpenWindowsAutomatically: true,
            ),
            onWebViewCreated: (controller) {
              _webViewController = controller;
              controller.addJavaScriptHandler(
                handlerName: 'Channel',
                callback: (args) async {
                  // 로그인 성공 시 FCM 토큰 발급 및 백엔드로 전송
                  int memberId = args[0];
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
