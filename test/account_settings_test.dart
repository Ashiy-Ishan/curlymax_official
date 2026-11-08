import 'package:curlymax/main.dart';
import 'package:curlymax/notifications.dart';
import 'package:curlymax/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AccountStore extends Store {
  AccountStore(super.prefs);
  bool authenticated = true;
  int deletions = 0;
  @override
  bool get signedIn => authenticated;
  @override
  String get userLabel => 'viewer@example.test';
  @override
  Future<List<RecordData>> attempts() async => [];
  @override
  Future<void> deleteAccount() async {
    deletions++;
    authenticated = false;
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'Who am I exposes logout and requires typed confirmation before deletion',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = AccountStore(await SharedPreferences.getInstance());
      final notifications = Notifications();
      addTearDown(store.dispose);
      addTearDown(notifications.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: AccountScreen(store: store, notifications: notifications),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Who am I'), findsOneWidget);
      expect(find.text('viewer@example.test'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);
      await tester.tap(find.text('Clear all my data'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Delete my account'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.deletions, 0);
      await tester.tap(find.text('Clear all my data'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'DELETE');
      await tester.pump();
      await tester.tap(find.text('Delete my account'));
      await tester.pumpAndSettle();
      expect(store.deletions, 1);
      expect(store.signedIn, isFalse);
      expect(find.text('Guest viewer'), findsOneWidget);
    },
  );
}
