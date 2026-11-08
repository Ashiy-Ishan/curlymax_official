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
    client = SupabaseClient(
      'https://unit.test',
      'public-test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    store = Store(
      await SharedPreferences.getInstance(),
      client: client,
      backendUrl: 'https://unit.test',
    );
    notifications = Notifications();
  });
  tearDown(() async {
    store.dispose();
    notifications.dispose();
    await client.dispose();
  });
  Widget home() => MaterialApp(
    theme: ThemeData.dark(useMaterial3: true),
    home: Home(key: UniqueKey(), store: store, notifications: notifications),
  );

  testWidgets(
    'Unconfigured build gives a real setup state and no sample content',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: const ConfigurationScreen(details: 'Missing project settings'),
        ),
      );
      expect(
        find.text('This installation is not connected yet.'),
        findsOneWidget,
      );
      expect(find.textContaining('DEMO'), findsNothing);
      expect(find.text('Continue as demo viewer'), findsNothing);
      expect(find.bySemanticsLabel('CURLYmax app logo'), findsOneWidget);
    },
  );

  testWidgets('Guest sees only supplied catalog content and latest upload', (
    tester,
  ) async {
    store.channels = [
      {'id': 'c1', 'name': 'Ashiy Ish', 'handle': '@ashiy_ish'},
    ];
    store.sections = [
      {'id': 's1', 'channel_id': 'c1', 'name': 'Latest videos'},
    ];
    store.videos = [
      {
        'id': 'v1',
        'channel_id': 'c1',
        'section_id': 's1',
        'title': 'Published channel upload',
        'youtube_id': 'abcdefghijk',
      },
    ];
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();
    expect(find.text('LATEST UPLOAD'), findsOneWidget);
    expect(find.text('Published channel upload'), findsWidgets);
    expect(find.textContaining('DEMO'), findsNothing);
    expect(store.signedIn, isFalse);
  });

  testWidgets('No catalog produces an honest empty state', (tester) async {
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();
    expect(find.text('Something good is on the way'), findsOneWidget);
    expect(find.text('LATEST UPLOAD'), findsNothing);
  });

  testWidgets(
    'Channel selector appears dynamically and filters channel content',
    (tester) async {
      store.channels = [
        {'id': 'c1', 'name': 'Ashiy Ish', 'handle': '@ashiy_ish'},
      ];
      await tester.pumpWidget(home());
      await tester.pumpAndSettle();
      expect(find.byTooltip('Choose channel'), findsOneWidget);
      store.channels.add({
        'id': 'c2',
        'name': 'CURLYmax Tech',
        'handle': '@curlymaxtech',
      });
      await tester.pumpWidget(home());
      await tester.pumpAndSettle();
      final selector = find.byTooltip('Choose channel');
      expect(selector, findsOneWidget);
      await tester.ensureVisible(selector);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('CURLYmax Tech').last);
      await tester.pumpAndSettle();
      expect(find.text('@curlymaxtech'), findsOneWidget);
      expect(store.prefs.getString('selected_channel:https://unit.test'), 'c2');
      await tester.pumpWidget(home());
      await tester.pumpAndSettle();
      expect(find.text('@curlymaxtech'), findsOneWidget);
      expect(find.text('Something good is on the way'), findsOneWidget);
    },
  );

  testWidgets('Sign-in presents real Google and email controls only', (
    tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: AuthScreen(store: store)));
    await tester.pumpAndSettle();
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Sign in with email'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('Continue as demo viewer'), findsNothing);
    await tester.tap(find.text('Sign in with email'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter an email and a password of at least 8 characters.'),
      findsOneWidget,
    );
  });
  test('Catalog sorting uses upload timestamps and real view counts only', () {
    store.videos = [
      {
        'id': 'old',
        'channel_id': 'c',
        'youtube_published_at': '2020-01-01',
        'published_at': '2025-01-01',
        'view_count': 900,
      },
      {
        'id': 'new',
        'channel_id': 'c',
        'youtube_published_at': '2024-01-01',
        'view_count': 100,
      },
      {'id': 'manual', 'channel_id': 'c', 'published_at': '2023-01-01'},
    ];
    store.playlistVideos = [
      {'playlist_id': 'p', 'video_id': 'new'},
      {'playlist_id': 'p', 'video_id': 'old'},
    ];
    expect(store.channelUploads('c').map((v) => v['id']), [
      'new',
      'manual',
      'old',
    ]);
    expect(store.channelUploads('c', playlistId: 'p').map((v) => v['id']), [
      'new',
      'old',
    ]);
    expect(store.popularUploads('c').map((v) => v['id']), ['old', 'new']);
  });

  testWidgets(
    'Mobile playlist selection filters compact cards and exposes play semantics',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      store.channels = [
        {'id': 'c', 'name': 'Channel', 'handle': '@channel'},
      ];
      store.playlists = [
        {'id': 'p1', 'channel_id': 'c', 'title': 'Learning'},
        {'id': 'p2', 'channel_id': 'c', 'title': 'Empty collection'},
      ];
      store.videos = [
        {
          'id': 'v',
          'channel_id': 'c',
          'title': 'Learn something',
          'youtube_id': 'abcdefghijk',
          'published_at': '2024-01-01',
        },
      ];
      store.playlistVideos = [
        {'playlist_id': 'p1', 'video_id': 'v'},
      ];
      await tester.pumpWidget(home());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Playlists'));
      await tester.pumpAndSettle();
      expect(find.byType(CompactVideoCard), findsOneWidget);
      expect(find.text('Learn something'), findsOneWidget);
      final semantics = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel(RegExp('Play Learn something')),
        findsOneWidget,
      );
      semantics.dispose();
      await tester.tap(find.text('Empty collection').first);
      await tester.pumpAndSettle();
      expect(find.text('This playlist is waiting for videos'), findsOneWidget);
      expect(find.byType(CompactVideoCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Playlist tab without catalog explains empty state', (
    tester,
  ) async {
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Playlists'));
    await tester.pumpAndSettle();
    expect(find.text('No playlists yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Compact video remains readable at large text on a narrow phone',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: CompactVideoCard(
                  video: {
                    'title': 'A longer video title that remains readable',
                    'youtube_id': 'abcdefghijk',
                    'view_count': 123456,
                  },
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('A longer video title that remains readable'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Channel picker shows icons and updates while open', (tester) async {
    store.channels = [{'id': 'a', 'name': 'Ashiy Ish', 'handle': '@a'}];
    await tester.pumpWidget(home());
    await tester.tap(find.byTooltip('Choose channel'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a channel'), findsOneWidget);
    expect(find.text('AI'), findsWidgets);
    store.channels.addAll([
      {'id': 'b', 'name': 'Tech', 'handle': '@tech'},
      {'id': 'hidden', 'name': 'Inactive', 'active': false},
    ]);
    // A catalog refresh notifies the same listener used by the open picker.
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    store.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Tech'), findsOneWidget);
    expect(find.text('Inactive'), findsNothing);
    await tester.tap(find.text('Tech'));
    await tester.pumpAndSettle();
    expect(find.text('@tech'), findsOneWidget);
    expect(find.text('Choose a channel'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Invalid remembered channel falls back to an active channel', (tester) async {
    await store.prefs.setString('selected_channel:https://unit.test', 'removed');
    store.channels = [{'id': 'a', 'name': 'Active', 'handle': '@active'}];
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();
    expect(find.text('@active'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

}
