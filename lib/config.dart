import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Public client configuration. Server secrets never belong in a Flutter build.
abstract final class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: String.fromEnvironment('SUPABASE_ANON_KEY'),
  );
  static const authRedirect = 'com.curlymax.app://login-callback/';
  static const fcmEnabled = bool.fromEnvironment(
    'FCM_ENABLED',
    defaultValue: true,
  );
  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
  static const firebaseSenderId = String.fromEnvironment('FIREBASE_SENDER_ID');
  static const firebaseProjectId = String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
  );

  static String? validateSupabase({String? url, String? key}) {
    final projectUrl = url ?? supabaseUrl;
    final publicKey = key ?? supabaseKey;
    final uri = Uri.tryParse(projectUrl);
    final localDebug =
        !kReleaseMode &&
        uri != null &&
        {'localhost', '127.0.0.1', '10.0.2.2'}.contains(uri.host);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && !(localDebug && uri.scheme == 'http')) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        projectUrl.toUpperCase().contains('YOUR_PROJECT')) {
      return 'Set SUPABASE_URL to your project’s HTTPS URL in config/live.json.';
    }
    if (publicKey.startsWith('sb_secret_')) {
      return 'Use a public publishable/anon key. A Supabase secret key must never be included in the app.';
    }
    if (publicKey.startsWith('sb_publishable_') && publicKey.length > 20) {
      return null;
    }
    try {
      final parts = publicKey.split('.');
      if (parts.length == 3 && parts[2].isNotEmpty) {
        final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
        );
        if (payload is Map && payload['role'] == 'service_role') {
          return 'Use a public publishable/anon key. A service-role key must never be included in the app.';
        }
        if (payload is Map && payload['role'] == 'anon') return null;
      }
    } catch (_) {
      /* A malformed key is reported below. */
    }
    return 'Set SUPABASE_PUBLISHABLE_KEY (or SUPABASE_ANON_KEY) to the public project key in config/live.json.';
  }

  static String? get firebaseError {
    if (!fcmEnabled) return 'Notifications are disabled in this build.';
    if (firebaseApiKey.isEmpty ||
        firebaseAppId.isEmpty ||
        firebaseSenderId.isEmpty ||
        firebaseProjectId.isEmpty ||
        firebaseProjectId.contains('PROJECT_ID')) {
      return 'Firebase notifications need the public Android client settings.';
    }
    return null;
  }
}
