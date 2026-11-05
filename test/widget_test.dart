import 'package:flutter/material.dart';
import 'package:curlymax/notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:curlymax/main.dart';
import 'package:curlymax/store.dart';

void main() {
  testWidgets('Guest sees labeled catalog and latest video', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = Store(await SharedPreferences.getInstance());
    await tester.pumpWidget(CurlyApp(store: store));
    await tester.pumpAndSettle();
    expect(
      find.text('DEMO MODE · Sample videos & local practice data'),
      findsOneWidget,
    );
    expect(find.text('LATEST UPLOAD'), findsOneWidget);
    expect(find.byTooltip('Account and settings'), findsOneWidget);
    expect(store.signedIn, isFalse);
  });
  test('Demo notes persist, edit, delete; scores retry and persist', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = Store(prefs);
    await store.init();
    await expectLater(store.notes('demo-video'), throwsStateError);
    await store.signInDemo();
    await store.saveNote('demo-video', 'First thought');
    final id = (await store.notes('demo-video')).single['id'];
    await store.saveNote('demo-video', 'Revised thought', id: id);
    expect((await store.notes('demo-video')).single['body'], 'Revised thought');
    expect(await store.notes('demo-video-2'), isEmpty);
    await store.deleteNote(id);
    expect(await store.notes('demo-video'), isEmpty);
    expect((await store.submit('demo-quiz', {'q1': 0, 'q2': 1}))['score'], 2);
    expect((await store.submit('demo-quiz', {'q1': 1, 'q2': 0}))['score'], 0);
    final second = Store(prefs);
    await second.init();
    expect(second.signedIn, isTrue);
    expect((await second.attempts()).length, 2);
    await second.remember({'kind': 'quiz', 'item_id': 'demo-quiz'});
    expect(Store(prefs).pending?['item_id'], 'demo-quiz');
    await second.signOut();
    await expectLater(second.attempts(), throwsStateError);
    store.dispose();
    second.dispose();
  });
  testWidgets('Channel selector appears from catalog data and filters videos', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = Store(await SharedPreferences.getInstance());
    await store.init();
    Widget home() => MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Home(
        key: UniqueKey(),
        store: store,
        notifications: Notifications(),
      ),
    );
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    store.channels.add({
      'id': 'tech',
      'name': 'CURLYmax Tech',
      'handle': '@curlymaxtech',
    });
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    await tester.ensureVisible(find.byType(DropdownButtonFormField<String>));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CURLYmax Tech').last);
    await tester.pumpAndSettle();
    expect(find.text('Something good is on the way'), findsOneWidget);
    expect(find.text('@curlymaxtech'), findsOneWidget);
    store.dispose();
  });
}
