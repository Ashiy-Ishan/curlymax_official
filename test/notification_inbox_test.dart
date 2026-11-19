import 'dart:convert';
import 'package:curlymax/notification_inbox.dart';
import 'package:curlymax/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late SharedPreferences prefs;
  late SupabaseClient client;
  final paths = <String>[];
  const event = '11111111-1111-1111-1111-111111111111';
  const quiz = '22222222-2222-2222-2222-222222222222';
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    paths.clear();
    client = SupabaseClient(
        'https://unit.test',
        'public-test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          return http.Response(
            jsonEncode([
              {
                'id': event,
                'kind': 'quiz',
                'item_id': quiz,
                'title': 'Published quiz',
                'created_at': '2026-11-19T10:00:00Z',
              },
            ]),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );

  });
  tearDown(() => client.dispose());
  testWidgets(
    'Guest inbox loads only public updates and opens the exact quiz destination',
    (tester) async {
      final store = Store(prefs, client: client);
      addTearDown(store.dispose);

      RecordData? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: NotificationInbox(
            store: store,
            onOpen: (value) => opened = value,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Published quiz'), findsOneWidget);
      expect(find.textContaining('Sign in to synchronize'), findsOneWidget);
      expect(paths, ['/rest/v1/notifications']);
      await tester.tap(find.text('Published quiz'));
      await tester.pumpAndSettle();
      expect(opened, {'kind': 'quiz', 'item_id': quiz, 'event_id': event});
      expect(
        paths.any((path) => path.contains('mark_notification_read')),
        false,
      );
    },
  );
}
