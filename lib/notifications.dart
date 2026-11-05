import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'store.dart';

class Notifications {
  final local = FlutterLocalNotificationsPlugin();
  bool available = false;
  void Function(RecordData)? open;
  Future<void> init(void Function(RecordData) onOpen) async {
    open = onOpen;
    if (demo || !const bool.fromEnvironment('FCM_ENABLED')) return;
    try {
      // Values are public Firebase client identifiers, never a service account key.
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: String.fromEnvironment('FIREBASE_API_KEY'),
          appId: String.fromEnvironment('FIREBASE_APP_ID'),
          messagingSenderId: String.fromEnvironment('FIREBASE_SENDER_ID'),
          projectId: String.fromEnvironment('FIREBASE_PROJECT_ID'),
        ),
      );
      await local.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('ic_notification'),
        ),
        onDidReceiveNotificationResponse: (r) {
          if (r.payload != null) {
            onOpen(Map<String, dynamic>.from(jsonDecode(r.payload!)));
          }
        },
      );
      await local
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              'curlymax_updates',
              'CURLYmax updates',
              description: 'New videos and quizzes',
              importance: Importance.high,
            ),
          );
      final launch = await local.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true &&
          launch?.notificationResponse?.payload != null) {
        onOpen(
          Map<String, dynamic>.from(
            jsonDecode(launch!.notificationResponse!.payload!),
          ),
        );
      }
      FirebaseMessaging.onMessageOpenedApp.listen((m) => onOpen(m.data));
      FirebaseMessaging.onMessage.listen((m) async {
        final prefs = await SharedPreferences.getInstance();
        if (!(prefs.getBool('notifications_enabled') ?? false)) return;
        final event = m.data['event_id'];
        final seen = prefs.getStringList('notification_events') ?? [];
        if (event == null || seen.contains(event)) return;
        await prefs.setStringList('notification_events', [
          event,
          ...seen.take(99),
        ]);
        await local.show(
          event.hashCode & 0x7fffffff,
          m.notification?.title ?? 'CURLYmax',
          m.notification?.body ?? 'Something new to explore',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'curlymax_updates',
              'CURLYmax updates',
              channelDescription: 'New videos and quizzes',
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
          payload: jsonEncode(m.data),
        );
      });
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) onOpen(initial.data);
      available = true;
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('notifications_enabled') ?? false) {
        await FirebaseMessaging.instance.setAutoInitEnabled(true);
        await FirebaseMessaging.instance.subscribeToTopic('curlymax_public');
      }
    } catch (_) {
      available = false;
    }
  }

  Future<bool> enable(bool value) async {
    if (!available) {
      throw StateError(
        'Notifications require a configured Firebase Android build.',
      );
    }
    if (value) {
      final permission = await FirebaseMessaging.instance.requestPermission();
      if (permission.authorizationStatus != AuthorizationStatus.authorized) {
        return false;
      }
      await FirebaseMessaging.instance.setAutoInitEnabled(true);
      await FirebaseMessaging.instance.subscribeToTopic('curlymax_public');
    } else {
      await FirebaseMessaging.instance.unsubscribeFromTopic('curlymax_public');
      await FirebaseMessaging.instance.deleteToken();
      await FirebaseMessaging.instance.setAutoInitEnabled(false);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications_enabled', value);
    return value;
  }
}
