import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef RecordData = Map<String, dynamic>;
const demo = bool.fromEnvironment('DEMO', defaultValue: true);
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseKey = String.fromEnvironment('SUPABASE_ANON_KEY');

class Store extends ChangeNotifier {
  Store(this.prefs);
  final SharedPreferences prefs;
  SupabaseClient get db => Supabase.instance.client;
  bool demoUser = false;
  bool get signedIn => demo ? demoUser : db.auth.currentUser != null;
  String get userLabel => demo
      ? 'Demo viewer · local data'
      : db.auth.currentUser?.email ?? 'Viewer';
  List<RecordData> channels = [], sections = [], videos = [], quizzes = [];
  bool loading = false;
  String? error;
  RealtimeChannel? subscription;
  StreamSubscription<AuthState>? authSubscription;
  Timer? retry;
  bool disposed = false;
  bool _refreshAgain = false;
  Completer<void>? _refreshComplete;
  VoidCallback? onAuthenticated;

  Future<void> init() async {
    if (demo) {
      demoUser = prefs.getBool('demo_user') ?? false;
    } else {
      final cached = prefs.getString('catalog:$supabaseUrl');
      if (cached != null) {
        try {
          _assign(jsonDecode(cached) as RecordData);
        } catch (_) {
          /* Discard invalid cache. */
        }
      }
      authSubscription = db.auth.onAuthStateChange.listen((event) {
        notifyListeners();
        if (event.event == AuthChangeEvent.signedIn) onAuthenticated?.call();
      });
      subscription = db
          .channel('catalog')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            callback: (_) => refresh(),
          );
      subscription!.subscribe((status, e) {
        if (status == RealtimeSubscribeStatus.subscribed) refresh();
        if (status == RealtimeSubscribeStatus.channelError ||
            status == RealtimeSubscribeStatus.timedOut) {
          error = 'Live updates interrupted. Pull to refresh; reconnecting…';
          notifyListeners();
        }
      });
      retry = Timer.periodic(const Duration(seconds: 45), (_) => refresh());
    }
    await refresh();
  }

  void _assign(RecordData data) {
    channels = List<RecordData>.from(data['channels']);
    sections = List<RecordData>.from(data['sections']);
    videos = List<RecordData>.from(data['videos']);
    quizzes = List<RecordData>.from(data['quizzes']);
  }

  Future<void> refresh() async {
    if (loading) {
      _refreshAgain = true;
      await _refreshComplete?.future;
      return;
    }
    final complete = Completer<void>();
    _refreshComplete = complete;
    loading = true;
    error = null;
    notifyListeners();
    try {
      if (demo) {
        channels = [
          {'id': 'channel-demo', 'name': 'Ashiy Ish', 'handle': '@ashiy_ish'},
        ];
        sections = [
          {
            'id': 'learn',
            'channel_id': 'channel-demo',
            'name': 'Learn & explore',
          },
          {
            'id': 'behind',
            'channel_id': 'channel-demo',
            'name': 'Behind the channel',
          },
        ];
        videos = [
          {
            'id': 'demo-video',
            'channel_id': 'channel-demo',
            'section_id': 'learn',
            'title': 'Small ideas. Big possibilities.',
            'description':
                'Demo sample: an introduction to Flutter from the Flutter team. This is placeholder content, not an upload from @ashiy_ish. Connect Supabase and publish your own links to replace it.',
            'youtube_id': 'fq4N0hgOWzU',
            'published_at': '2026-11-04T10:00:00Z',
          },
          {
            'id': 'demo-video-2',
            'channel_id': 'channel-demo',
            'section_id': 'behind',
            'title': 'Make something you’re proud of',
            'description':
                'Demo sample: Flutter Basic Training by Fireship. This is not an @ashiy_ish upload. Explore the player and save a private note.',
            'youtube_id': '1xipg02Wu8s',
            'published_at': '2026-11-03T10:00:00Z',
          },
        ];
        quizzes = [
          {
            'id': 'demo-quiz',
            'video_id': 'demo-video',
            'title': 'A quick Flutter check',
          },
        ];
      } else {
        final results = await Future.wait([
          db.from('channels').select().eq('active', true).order('position'),
          db.from('sections').select().eq('active', true).order('position'),
          db
              .from('videos')
              .select()
              .eq('status', 'published')
              .order('published_at', ascending: false),
          db.from('quizzes').select().eq('status', 'published'),
        ]).timeout(const Duration(seconds: 20));
        _assign({
          'channels': results[0],
          'sections': results[1],
          'videos': results[2],
          'quizzes': results[3],
        });
        await prefs.setString(
          'catalog:$supabaseUrl',
          jsonEncode({
            'channels': channels,
            'sections': sections,
            'videos': videos,
            'quizzes': quizzes,
          }),
        );
      }
    } catch (_) {
      error =
          'Can’t reach CURLYmax. Check your connection and try again. Saved catalog may be out of date.';
    } finally {
      loading = false;
      if (!disposed) notifyListeners();
      if (_refreshAgain && !disposed) {
        _refreshAgain = false;
        await refresh();
      }
      complete.complete();
    }
  }

  Future<void> remember(RecordData destination) =>
      prefs.setString('pending_destination', jsonEncode(destination));
  RecordData? get pending {
    final raw = prefs.getString('pending_destination');
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as RecordData;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearPending() => prefs.remove('pending_destination');
  Future<void> signInDemo() async {
    demoUser = true;
    await prefs.setBool('demo_user', true);
    notifyListeners();
    onAuthenticated?.call();
  }

  Future<void> signOut() async {
    await clearPending();
    if (demo) {
      demoUser = false;
      await prefs.setBool('demo_user', false);
    } else {
      await db.auth.signOut();
    }
    notifyListeners();
  }

  List<RecordData> _local(String key) =>
      List<RecordData>.from(jsonDecode(prefs.getString(key) ?? '[]'));
  Future<List<RecordData>> notes(String video) async {
    if (!signedIn) throw StateError('Sign in required');
    if (demo) {
      return _local('demo_notes').where((n) => n['video_id'] == video).toList();
    }
    return List<RecordData>.from(
      await db
          .from('notes')
          .select()
          .eq('video_id', video)
          .order('updated_at', ascending: false),
    );
  }

  Future<void> saveNote(String video, String body, {String? id}) async {
    if (!signedIn) throw StateError('Sign in required');
    if (demo) {
      final rows = _local('demo_notes');
      rows.removeWhere((n) => n['id'] == id);
      rows.insert(0, {
        'id': id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        'video_id': video,
        'body': body,
        'updated_at': DateTime.now().toIso8601String(),
      });
      await prefs.setString('demo_notes', jsonEncode(rows));
    } else if (id == null) {
      await db.from('notes').insert({'video_id': video, 'body': body});
    } else {
      await db
          .from('notes')
          .update({
            'body': body,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', id);
    }
  }

  Future<void> deleteNote(String id) async {
    if (!signedIn) throw StateError('Sign in required');
    if (demo) {
      final rows = _local('demo_notes')..removeWhere((n) => n['id'] == id);
      await prefs.setString('demo_notes', jsonEncode(rows));
    } else {
      await db.from('notes').delete().eq('id', id);
    }
  }

  Future<List<RecordData>> questions(String quiz) async {
    if (!signedIn) throw StateError('Sign in required');
    if (demo) {
      return [
        {
          'id': 'q1',
          'prompt': 'Which language is used to build Flutter apps?',
          'options': ['Dart', 'Python', 'SQL'],
        },
        {
          'id': 'q2',
          'prompt': 'What is Flutter used for?',
          'options': [
            'Editing video files',
            'Building apps from one codebase',
            'Hosting databases',
          ],
        },
      ];
    }
    return List<RecordData>.from(
      await db
          .from('questions')
          .select('id,prompt,options,position')
          .eq('quiz_id', quiz)
          .order('position'),
    );
  }

  Future<RecordData> submit(String quiz, Map<String, int> answers) async {
    if (!signedIn) throw StateError('Sign in required');
    if (!demo) {
      return Map<String, dynamic>.from(
        await db.rpc('submit_quiz', params: {'quiz': quiz, 'answers': answers}),
      );
    }
    final result = {
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'quiz_id': quiz,
      'score': (answers['q1'] == 0 ? 1 : 0) + (answers['q2'] == 1 ? 1 : 0),
      'total': 2,
      'submitted_at': DateTime.now().toIso8601String(),
    };
    final history = _local('demo_attempts')..insert(0, result);
    await prefs.setString('demo_attempts', jsonEncode(history));
    return result;
  }

  Future<List<RecordData>> attempts() async {
    if (!signedIn) throw StateError('Sign in required');
    if (demo) return _local('demo_attempts');
    return List<RecordData>.from(
      await db
          .from('attempts')
          .select()
          .order('submitted_at', ascending: false),
    );
  }

  @override
  void dispose() {
    disposed = true;
    retry?.cancel();
    authSubscription?.cancel();
    if (subscription != null) db.removeChannel(subscription!);
    super.dispose();
  }
}
