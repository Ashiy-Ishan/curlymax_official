import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:curlymax/main.dart' as app;
import 'package:shared_preferences/shared_preferences.dart';

Future<void> waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsWidgets);
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android guest → gated notes → CRUD → quiz → retry → history', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await app.main();
    await tester.pumpAndSettle();
    expect(find.text('LATEST UPLOAD'), findsOneWidget);
    await tester.tap(find.text('Small ideas. Big possibilities.').first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Open in YouTube'), findsOneWidget);
    await tester.tap(find.text('My notes'));
    await tester.pumpAndSettle();
    expect(find.text('Keep your ideas close'), findsOneWidget);
    await tester.tap(find.text('Sign in to continue'));
    await tester.pumpAndSettle();
    await waitFor(tester, find.text('Continue as demo viewer'));
    await tester.ensureVisible(find.text('Continue as demo viewer'));
    await tester.tap(find.text('Continue as demo viewer'));
    await tester.pumpAndSettle();
    await waitFor(tester, find.text('Add note'));
    expect(find.text('Add note'), findsOneWidget);
    await tester.tap(find.text('Add note'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Android test idea');
    await tester.tap(find.text('Save note'));
    await tester.pumpAndSettle();
    await waitFor(tester, find.text('Android test idea'));
    expect(find.text('Android test idea'), findsOneWidget);
    await tester.tap(find.byTooltip('Edit note'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Edited Android idea');
    await tester.tap(find.text('Save note'));
    await tester.pumpAndSettle();
    await waitFor(tester, find.text('Edited Android idea'));
    expect(find.text('Edited Android idea'), findsOneWidget);
    await tester.tap(find.byTooltip('Delete note'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await waitFor(tester, find.text('An idea worth keeping?'));
    expect(find.text('Edited Android idea'), findsNothing);
    await tester.tap(find.text('Quiz'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A quick Flutter check'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dart'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Building apps from one codebase'));
    await tester.tap(find.text('Building apps from one codebase'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Submit answers'));
    await tester.tap(find.text('Submit answers'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('0 of 2 answered'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Account and settings'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Cold quiz destination survives demo authentication', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await prefs.setString(
      'pending_destination',
      jsonEncode({'kind': 'quiz', 'item_id': 'demo-quiz'}),
    );
    await app.main();
    await tester.pumpAndSettle();
    await waitFor(tester, find.text('Continue as demo viewer'));
    expect(find.text('Continue as demo viewer'), findsOneWidget);
    await tester.ensureVisible(find.text('Continue as demo viewer'));
    await tester.tap(find.text('Continue as demo viewer'));
    await tester.pumpAndSettle();
    await waitFor(tester, find.text('0 of 2 answered'));
    expect(find.text('A quick Flutter check'), findsOneWidget);
    expect(find.text('0 of 2 answered'), findsOneWidget);
    expect(prefs.getString('pending_destination'), isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Account sign-in closes the auth screen and sign-out works', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await app.main();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Account and settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try the demo viewer'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Continue as demo viewer'));
    await tester.tap(find.text('Continue as demo viewer'));
    await waitFor(tester, find.text('Demo viewer · local data'));
    expect(find.text('Your space'), findsOneWidget);
    await tester.ensureVisible(find.text('Sign out'));
    await tester.tap(find.text('Sign out'));
    await waitFor(tester, find.text('Try the demo viewer'));
    expect(tester.takeException(), isNull);
  });
}
