import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:curlymax/config.dart';
import 'package:curlymax/notifications.dart';
import 'package:curlymax/store.dart';

String jwt(String role) =>
    '${base64Url.encode(utf8.encode('{"alg":"HS256"}')).replaceAll('=', '')}.${base64Url.encode(utf8.encode(jsonEncode({'role': role, 'exp': 4102444800}))).replaceAll('=', '')}.test-signature';
const userId = '10000000-0000-0000-0000-000000000001';
const videoId = '20000000-0000-0000-0000-000000000001';

void main() {
  group('Client configuration', () {
    test('Requires a real endpoint and a public key', () {
      expect(AppConfig.validateSupabase(url: '', key: ''), isNotNull);
      expect(
        AppConfig.validateSupabase(
          url: 'http://public.example',
          key: jwt('anon'),
        ),
        isNotNull,
      );
      expect(
        AppConfig.validateSupabase(
          url: 'https://project.supabase.co',
          key: jwt('anon'),
        ),
        isNull,
      );
      expect(
        AppConfig.validateSupabase(
          url: 'https://project.supabase.co',
          key: 'sb_publishable_test-public-client-key',
        ),
        isNull,
      );
    });
    test('Rejects privileged keys before initializing the app', () {
      expect(
        AppConfig.validateSupabase(
          url: 'https://project.supabase.co',
          key: 'sb_secret_privileged',
        ),
        contains('secret key'),
      );
      expect(
        AppConfig.validateSupabase(
          url: 'https://project.supabase.co',
          key: jwt('service_role'),
        ),
        contains('service-role'),
      );
    });
    test(
      'Notification destinations accept catalog IDs, never URLs or unknown types',
      () {
        expect(notificationDestination({'kind': 'quiz', 'item_id': videoId}), {
          'kind': 'quiz',
          'item_id': videoId,
        });
        expect(
          notificationDestination({'kind': 'url', 'item_id': videoId}),
          isNull,
        );
        expect(
          notificationDestination({
            'kind': 'video',
            'item_id': 'https://example.com',
          }),
          isNull,
        );
        expect(
          notificationDestination({'kind': 'video', 'item_id': 42}),
          isNull,
        );
      },
    );
  });

  late Store store;
  late SharedPreferences prefs;
  late SupabaseClient client;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) respond;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    requests = [];
    respond = (request) async =>
        http.Response('[]', 200, headers: {'content-type': 'application/json'});
    client = SupabaseClient(
      'https://unit.test',
      jwt('anon'),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        requests.add(r);
        final response = await respond(r);
        return http.Response(
          response.body,
          response.statusCode,
          headers: response.headers,
          request: r,
        );
      }),
    );
    store = Store(prefs, client: client, backendUrl: 'https://unit.test');
  });
  tearDown(() async {
    store.dispose();
    await client.dispose();
  });
  Future<void> authenticate() => client.auth.recoverSession(
    jsonEncode({
      'access_token': jwt('authenticated'),
      'refresh_token': 'test-refresh-token',
      'token_type': 'bearer',
      'expires_in': 3600,
      'user': {
        'id': userId,
        'aud': 'authenticated',
        'email': 'viewer@example.test',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2026-11-06T00:00:00Z',
      },
    }),
  );

  test(
    'Guests cannot read or mutate private data through the repository',
    () async {
      await expectLater(store.notes(videoId), throwsStateError);
      await expectLater(
        store.saveNote(videoId, 'Private note'),
        throwsStateError,
      );
      await expectLater(store.deleteNote('note-id'), throwsStateError);
      await expectLater(store.questions('quiz-id'), throwsStateError);
      await expectLater(store.submit('quiz-id', {}), throwsStateError);
      await expectLater(store.attempts(), throwsStateError);
      expect(requests, isEmpty);
    },
  );

  test(
    'Quiz submission calls the grading RPC and returns its score verbatim',
    () async {
      await authenticate();
      respond = (r) async => http.Response(
        jsonEncode({
          'id': 'attempt-id',
          'user_id': userId,
          'quiz_id': 'quiz-id',
          'score': 1,
          'total': 7,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
      final result = await store.submit('quiz-id', {'question-id': 2});
      expect(result['score'], 1);
      expect(result['total'], 7);
      expect(requests.single.url.path, '/rest/v1/rpc/submit_quiz');
      expect(jsonDecode(requests.single.body), {
        'quiz': 'quiz-id',
        'answers': {'question-id': 2},
      });
      expect(prefs.getKeys(), isEmpty);
    },
  );

  test('Notes are sent to Supabase without a client-supplied owner', () async {
    await authenticate();
    respond = (r) async => http.Response('', 201);
    await store.saveNote(videoId, '  A private thought  ');
    expect(requests.single.method, 'POST');
    expect(requests.single.url.path, '/rest/v1/notes');
    expect(jsonDecode(requests.single.body), {
      'video_id': videoId,
      'body': 'A private thought',
    });
    expect(prefs.getKeys(), isEmpty);
  });

  test(
    'Editing a missing note fails instead of pretending it was saved',
    () async {
      await authenticate();
      await expectLater(
        store.saveNote(videoId, 'Updated', id: 'missing-note'),
        throwsStateError,
      );
      expect(requests.single.method, 'PATCH');
      expect(requests.single.url.queryParameters['id'], 'eq.missing-note');
      expect(requests.single.url.queryParameters['video_id'], 'eq.$videoId');
    },
  );

  test(
    'Catalog loads published data, caches it, and preserves it after a network error',
    () async {
      respond = (r) async {
        final table = r.url.pathSegments.last;
        final rows = switch (table) {
          'channels' => [
            {
              'id': 'c',
              'name': 'Channel',
              'handle': '@channel',
              'active': true,
            },
          ],
          'sections' => [
            {'id': 's', 'channel_id': 'c', 'name': 'Section', 'active': true},
          ],
          'videos' => [
            {
              'id': videoId,
              'channel_id': 'c',
              'section_id': 's',
              'title': 'Server upload',
            },
          ],
          'quizzes' => [
            {'id': 'q', 'video_id': videoId},
          ],
          'playlists' => [
            {'id': 'p', 'channel_id': 'c', 'title': 'Learning'},
          ],
          'playlist_videos' => [
            {'playlist_id': 'p', 'video_id': videoId},
          ],
          _ => [],
        };
        return http.Response(
          jsonEncode(rows),
          200,
          headers: {'content-type': 'application/json'},
        );
      };
      await store.refresh();
      expect(store.videos.single['title'], 'Server upload');
      expect(store.quizzes.single['id'], 'q');
      expect(store.playlists.single['id'], 'p');
      expect(store.playlistVideos.single['video_id'], videoId);
      expect(
        jsonDecode(
          prefs.getString('catalog:https://unit.test')!,
        )['playlists'].length,
        1,
      );
      expect(prefs.getString('catalog:https://unit.test'), isNotNull);
      expect(
        requests
            .where((r) => r.url.path.endsWith('/videos'))
            .single
            .url
            .queryParameters['status'],
        'eq.published',
      );
      respond = (r) async => http.Response(
        '{"message":"offline"}',
        503,
        headers: {'content-type': 'application/json'},
      );
      await store.refresh();
      expect(store.error, contains('Can’t reach CURLYmax'));
      expect(store.videos.single['title'], 'Server upload');
    },
  );

  test(
    'Missing optional playlist tables do not block older catalog installations',
    () async {
      respond = (r) async => r.url.path.contains('playlist')
          ? http.Response(
              '{"code":"PGRST205","message":"missing table"}',
              404,
              headers: {'content-type': 'application/json'},
            )
          : http.Response(
              '[]',
              200,
              headers: {'content-type': 'application/json'},
            );
      await store.refresh();
      expect(store.error, isNull);
      expect(store.playlists, isEmpty);
      expect(store.playlistVideos, isEmpty);
    },
  );

  test(
    'Saved authentication destinations survive repository recreation',
    () async {
      await store.remember({'kind': 'quiz', 'item_id': videoId});
      final reopened = Store(
        prefs,
        client: client,
        backendUrl: 'https://unit.test',
      );
      expect(reopened.pending, {'kind': 'quiz', 'item_id': videoId});
      await reopened.clearPending();
      expect(store.pending, isNull);
      reopened.dispose();
    },
  );
}
