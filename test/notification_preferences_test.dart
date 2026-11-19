import 'package:curlymax/notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'Opt-out persists before a failed network cleanup and retries safely',
    () async {
      SharedPreferences.setMockInitialValues({'notifications_enabled': true});
      var calls = 0;
      var fail = true;
      final notifications = Notifications(
        stopTransport: () async {
          calls++;
          if (fail) throw StateError('offline');
        },
      );
      addTearDown(notifications.dispose);
      notifications.available = true;
      notifications.enabled = true;
      expect(await notifications.enable(false), false);
      final prefs = await SharedPreferences.getInstance();
      expect(notifications.enabled, false);
      expect(prefs.getBool('notifications_enabled'), false);
      expect(prefs.getBool('notifications_cleanup_pending'), true);
      expect(notifications.status, contains('retry'));
      fail = false;
      await notifications.enable(false);
      expect(calls, 2);
      expect(prefs.getBool('notifications_cleanup_pending'), false);
    },
  );
}
