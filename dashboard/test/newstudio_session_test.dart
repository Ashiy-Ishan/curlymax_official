import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:curlymax_dashboard/main.dart';

void main() {
  late SupabaseClient db;
  late List<String> requests;
  late Future<http.Response> Function(http.Request) responder;
  http.Response json(Object value, [int status = 200]) => http.Response(
    jsonEncode(value),
    status,
    headers: {'content-type': 'application/json'},
  );
  setUp(() {
    requests = [];
    responder = (request) async =>
        json(request.url.path.endsWith('is_owner') ? true : []);
    db = SupabaseClient(
      'https://example.supabase.co',
      'public-test',
      httpClient: MockClient((request) async {
        requests.add(request.url.path);
        if (request.url.path.endsWith('/token')) {
          final payload = base64Url.encode(
            utf8.encode(
              jsonEncode({
                'sub': 'user-a',
                'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
              }),
            ),
          );
          return json({
            'access_token': 'e30.$payload.signature',
            'refresh_token': 'test-refresh',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': {
              'id': 'user-a',
              'aud': 'authenticated',
              'email': 'owner@example.test',
              'created_at': '2026-01-01T00:00:00Z',
              'app_metadata': {},
              'user_metadata': {},
            },
          });
        }
        if (request.url.path.endsWith('/logout')) return json({});
        final response = await responder(request);
        return http.Response(
          response.body,
          response.statusCode,
          headers: response.headers,
          request: request,
        );
      }),
    );
  });
  tearDown(() async => db.dispose());
  Future<void> open(WidgetTester tester) async {
    await db.auth.signInWithPassword(
      email: 'owner@example.test',
      password: 'test-only',
    );
    await tester.pumpWidget(
      MaterialApp(home: Studio(client: db, realtimeEnabled: false)),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Failed owner request stays closed and is not labeled a denied owner',
    (tester) async {
      responder = (_) async => json({'message': 'offline'}, 503);
      await open(tester);
      expect(find.textContaining('This account is not an owner'), findsNothing);
      expect(find.text('Check access again'), findsOneWidget);
      expect(requests.any((p) => p.endsWith('/channels')), isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('Optional playlist outage does not hide the catalog', (
    tester,
  ) async {
    responder = (r) async {
      if (r.url.path.endsWith('is_owner')) return json(true);
      if (r.url.path.endsWith('/playlists')) {
        return json({'message': 'missing relation'}, 404);
      }
      if (r.url.path.endsWith('/channels')) {
        return json([
          {
            'id': 'c1',
            'name': 'Visible channel',
            'handle': '@channel',
            'active': true,
          },
        ]);
      }
      return json([]);
    };
    await open(tester);
    expect(
      find.text('Visible channel'),
      findsOneWidget,
      reason:
          '$requests / ${tester.widgetList<SelectableText>(find.byType(SelectableText)).map((t) => t.data).toList()}',
    );
    expect(find.textContaining('Playlists could not load'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Logout during a pending catalog request discards response and stops later queries',
    (tester) async {
      final pending = Completer<http.Response>();
      responder = (r) async =>
          r.url.path.endsWith('is_owner') ? json(true) : pending.future;
      await db.auth.signInWithPassword(
        email: 'owner@example.test',
        password: 'test-only',
      );
      await tester.pumpWidget(
        MaterialApp(home: Studio(client: db, realtimeEnabled: false)),
      );
      await tester.pump();
      await tester.pump();
      await db.auth.signOut();
      await tester.pump();
      final count = requests.length;
      pending.complete(
        json([
          {'id': 'secret', 'name': 'Stale private channel'},
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('Stale private channel'), findsNothing);
      expect(find.text('Sign in'), findsOneWidget);
      expect(requests.length, count);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('Burst refreshes coalesce and resume rechecks owner permission', (
    tester,
  ) async {
    await open(tester);
    final pending = Completer<http.Response>();
    var channels = 0;
    responder = (r) async {
      if (r.url.path.endsWith('is_owner')) return json(true);
      if (r.url.path.endsWith('/channels')) {
        channels++;
        if (channels == 1) return pending.future;
      }
      return json([]);
    };
    final dynamic state = tester.state(find.byType(Studio));
    final Future<void> first = state.refresh();
    await tester.pump();
    await state.refresh();
    await state.refresh();
    expect(channels, 1);
    pending.complete(json([]));
    await first;
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(channels, 2);
    final checks = requests.where((p) => p.endsWith('is_owner')).length;
    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(requests.where((p) => p.endsWith('is_owner')).length, checks + 1);
    await tester.pumpWidget(const SizedBox());
  });
}
