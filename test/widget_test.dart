import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:curlymax/main.dart';
import 'package:curlymax/notifications.dart';
import 'package:curlymax/store.dart';

void main() {
  late Store store;
  late SupabaseClient client;
  late Notifications notifications;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    client = SupabaseClient('https://unit.test', 'public-test-key', authOptions: const AuthClientOptions(autoRefreshToken: false));
    store = Store(await SharedPreferences.getInstance(), client: client, backendUrl: 'https://unit.test');
    notifications = Notifications();
  });
  tearDown(() async {
    store.dispose(); notifications.dispose(); await client.dispose();
  });
  Widget home() => MaterialApp(theme: ThemeData.dark(useMaterial3: true),
      home: Home(key: UniqueKey(), store: store, notifications: notifications));

  testWidgets('Unconfigured build gives a real setup state and no sample content', (tester) async {
    await tester.pumpWidget(MaterialApp(home: const ConfigurationScreen(details: 'Missing project settings')));
    expect(find.text('This installation is not connected yet.'), findsOneWidget);
    expect(find.textContaining('DEMO'), findsNothing);
    expect(find.text('Continue as demo viewer'), findsNothing);
    expect(find.bySemanticsLabel('CURLYmax app logo'), findsOneWidget);
  });

  testWidgets('Guest sees only supplied catalog content and latest upload', (tester) async {
    store.channels = [{'id': 'c1', 'name': 'Ashiy Ish', 'handle': '@ashiy_ish'}];
    store.sections = [{'id': 's1', 'channel_id': 'c1', 'name': 'Latest videos'}];
    store.videos = [{'id': 'v1', 'channel_id': 'c1', 'section_id': 's1', 'title': 'Published channel upload', 'youtube_id': 'abcdefghijk'}];
    await tester.pumpWidget(home()); await tester.pumpAndSettle();
    expect(find.text('LATEST UPLOAD'), findsOneWidget);
    expect(find.text('Published channel upload'), findsWidgets);
    expect(find.textContaining('DEMO'), findsNothing);
    expect(store.signedIn, isFalse);
  });

  testWidgets('No catalog produces an honest empty state', (tester) async {
    await tester.pumpWidget(home()); await tester.pumpAndSettle();
    expect(find.text('Something good is on the way'), findsOneWidget);
    expect(find.text('LATEST UPLOAD'), findsNothing);
  });

  testWidgets('Channel selector appears dynamically and filters channel content', (tester) async {
    store.channels = [{'id':'c1','name':'Ashiy Ish','handle':'@ashiy_ish'}];
    await tester.pumpWidget(home()); await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    store.channels.add({'id':'c2','name':'CURLYmax Tech','handle':'@curlymaxtech'});
    await tester.pumpWidget(home()); await tester.pumpAndSettle();
    final selector = find.byType(DropdownButtonFormField<String>);
    expect(selector, findsOneWidget);
    await tester.ensureVisible(selector); await tester.tap(selector); await tester.pumpAndSettle();
    await tester.tap(find.text('CURLYmax Tech').last); await tester.pumpAndSettle();
    expect(find.text('@curlymaxtech'), findsOneWidget);
    expect(find.text('Something good is on the way'), findsOneWidget);
  });

  testWidgets('Sign-in presents real Google and email controls only', (tester) async {
    await tester.pumpWidget(MaterialApp(home: AuthScreen(store:store))); await tester.pumpAndSettle();
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Sign in with email'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('Continue as demo viewer'), findsNothing);
    await tester.tap(find.text('Sign in with email')); await tester.pumpAndSettle();
    expect(find.text('Enter an email and a password of at least 8 characters.'), findsOneWidget);
  });
}
