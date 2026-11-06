import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:curlymax/main.dart' as app;
import 'package:curlymax/config.dart';

Future<void> waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 300 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsWidgets);
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Real account resumes quiz, server grades, notes sync and sign-out works',
    (tester) async {
      const email = String.fromEnvironment('TEST_EMAIL');
      const password = String.fromEnvironment('TEST_PASSWORD');
      const quizId = String.fromEnvironment('TEST_QUIZ_ID');
      const videoId = String.fromEnvironment('TEST_VIDEO_ID');
      expect(
        AppConfig.validateSupabase(),
        isNull,
        reason:
            'Supply the public project settings in a local test configuration file.',
      );
      expect(
        email.isNotEmpty &&
            password.isNotEmpty &&
            quizId.isNotEmpty &&
            videoId.isNotEmpty,
        isTrue,
        reason:
            'Requires a staging test account plus TEST_EMAIL, TEST_PASSWORD, TEST_QUIZ_ID and TEST_VIDEO_ID. Use scripts/run_live_android_test.py for isolated local fixtures.',
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'pending_destination',
        jsonEncode({'kind': 'quiz', 'item_id': quizId}),
      );
      await app.main();
      await waitFor(tester, find.text('Sign in with email'));
      await tester.enterText(find.byType(TextField).at(0), email);
      await tester.enterText(find.byType(TextField).at(1), password);
      await tester.ensureVisible(find.text('Sign in with email'));
      await tester.tap(find.text('Sign in with email'));
      await waitFor(tester, find.text('0 of 2 answered'));
      expect(Supabase.instance.client.auth.currentUser?.email, email);
      expect(prefs.getString('pending_destination'), isNull);
      await tester.tap(find.text('First correct option'));
      await tester.scrollUntilVisible(
        find.text('Second correct option'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Second correct option'));
      await tester.ensureVisible(find.text('Submit answers'));
      await tester.tap(find.text('Submit answers'));
      await waitFor(tester, find.text('2 / 2'));
      final attempts = await Supabase.instance.client
          .from('attempts')
          .select()
          .eq('quiz_id', quizId);
      expect(attempts, isNotEmpty);
      expect(attempts.last['score'], 2);
      await tester.tap(find.text('Try again'));
      await waitFor(tester, find.text('0 of 2 answered'));
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('My notes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add note'));
      await tester.pumpAndSettle();
      final note =
          'Android private note ${DateTime.now().microsecondsSinceEpoch}';
      await tester.enterText(find.byType(TextField), note);
      await tester.tap(find.text('Save note'));
      await waitFor(tester, find.text(note));
      final stored = await Supabase.instance.client
          .from('notes')
          .select()
          .eq('video_id', videoId)
          .eq('body', note);
      expect(stored.length, 1);
      expect(
        stored.single['user_id'],
        Supabase.instance.client.auth.currentUser!.id,
      );
      await tester.tap(find.byTooltip('Edit note'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '$note edited');
      await tester.tap(find.text('Save note'));
      await waitFor(tester, find.text('$note edited'));
      await tester.tap(find.byTooltip('Delete note'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await waitFor(tester, find.text('An idea worth keeping?'));
      final deleted = await Supabase.instance.client
          .from('notes')
          .select('id')
          .eq('id', stored.single['id']);
      expect(deleted, isEmpty);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Account and settings'));
      await tester.pumpAndSettle();
      await waitFor(tester, find.text('2 / 2'));
      await tester.ensureVisible(find.text('Sign out'));
      await tester.tap(find.text('Sign out'));
      await waitFor(tester, find.text('Sign in'));
      expect(Supabase.instance.client.auth.currentSession, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
