import 'dart:async';
import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'config.dart';
import 'store.dart';

RecordData? notificationDestination(Map<String, dynamic> data) {
  if (!{'video', 'quiz'}.contains(data['kind']) || data['item_id'] is! String)
    return null;
  final id = data['item_id'] as String;
  if (!RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  ).hasMatch(id))
    return null;
  return {'kind': data['kind'], 'item_id': id.toLowerCase()};
}

class Notifications extends ChangeNotifier {
  final local = FlutterLocalNotificationsPlugin();
  bool available = false, enabled = false, _disposed = false;
  String status = 'Connecting to notifications…';
  final List<StreamSubscription<RemoteMessage>> _subscriptions = [];
  final _displaying = <String>{};
  void Function(RecordData)? open;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _open(Map<String, dynamic> data) {
    final destination = notificationDestination(data);
    if (!_disposed && destination != null) open?.call(destination);
  }

  void _openPayload(String? payload) {
    if (payload == null) return;
    try {
      final value = jsonDecode(payload);
      if (value is Map<String, dynamic>) _open(value);
    } catch (_) {
      /* Invalid payloads never become navigation targets. */
    }
  }

  Future<void> init(void Function(RecordData) onOpen) async {
    open = onOpen;
    final prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool('notifications_enabled') ?? false;
    final configError = AppConfig.firebaseError;
    if (configError != null) {
      status = configError;
      _changed();
      return;
    }
    try {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: AppConfig.firebaseApiKey,
          appId: AppConfig.firebaseAppId,
          messagingSenderId: AppConfig.firebaseSenderId,
          projectId: AppConfig.firebaseProjectId,
        ),
      );
      if (_disposed) return;
      await local.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('ic_notification'),
        ),
        onDidReceiveNotificationResponse: (response) =>
            _openPayload(response.payload),
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
      if (launch?.didNotificationLaunchApp == true)
        _openPayload(launch?.notificationResponse?.payload);
      if (_disposed) return;
      _subscriptions.add(
        FirebaseMessaging.onMessageOpenedApp.listen((m) => _open(m.data)),
      );
      _subscriptions.add(
        FirebaseMessaging.onMessage.listen((message) async {
          try {
            await _foreground(message);
          } catch (_) {
            status = 'A notification could not be displayed. Try again later.';
            _changed();
          }
        }),
      );
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) _open(initial.data);
      available = true;
      status = 'Notify me about published videos and quizzes';
      _changed();
      if (enabled) {
        try {
          await FirebaseMessaging.instance.setAutoInitEnabled(true);
          await FirebaseMessaging.instance
              .subscribeToTopic('curlymax_public')
              .timeout(const Duration(seconds: 20));
        } catch (_) {
          status = 'Can’t reconnect to notifications. Check your connection.';
          _changed();
        }
      }
    } catch (_) {
      available = false;
      status =
          'Notifications could not start. Check this build’s Firebase setup and restart the app.';
      _changed();
    }
  }

  Future<void> _foreground(RemoteMessage message) async {
    final event = message.data['event_id'];
    if (_disposed ||
        !enabled ||
        event == null ||
        _displaying.contains(event) ||
        notificationDestination(message.data) == null)
      return;
    _displaying.add(event);
    try {
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getStringList('notification_events') ?? [];
      if (seen.contains(event)) return;
      await local.show(
        event.hashCode & 0x7fffffff,
        message.notification?.title ?? 'CURLYmax',
        message.notification?.body ?? 'Something new to explore',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'curlymax_updates',
            'CURLYmax updates',
            channelDescription: 'New videos and quizzes',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: jsonEncode(message.data),
      );
      await prefs.setStringList('notification_events', [
        event,
        ...seen.take(99),
      ]);
    } finally {
      _displaying.remove(event);
    }
  }

  Future<bool> enable(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value) {
      if (!available) throw StateError(status);
      final permission = await FirebaseMessaging.instance.requestPermission();
      if (permission.authorizationStatus != AuthorizationStatus.authorized) {
        enabled = false;
        await prefs.setBool('notifications_enabled', false);
        _changed();
        return false;
      }
      await FirebaseMessaging.instance.setAutoInitEnabled(true);
      await FirebaseMessaging.instance
          .subscribeToTopic('curlymax_public')
          .timeout(const Duration(seconds: 20));
    } else if (available) {
      await FirebaseMessaging.instance
          .unsubscribeFromTopic('curlymax_public')
          .timeout(const Duration(seconds: 20));
      await FirebaseMessaging.instance.deleteToken();
      await FirebaseMessaging.instance.setAutoInitEnabled(false);
    }
    enabled = value;
    await prefs.setBool('notifications_enabled', value);
    _changed();
    return value;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }
}
