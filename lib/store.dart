import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';

typedef RecordData = Map<String, dynamic>;

/// Live Supabase repository. Only the public catalog is cached on the device.
class Store extends ChangeNotifier {
  Store(
    this.prefs, {
    SupabaseClient? client,
    this.backendUrl = AppConfig.supabaseUrl,
  }) : _client = client;
  final SharedPreferences prefs;
  final SupabaseClient? _client;
  final String backendUrl;
  SupabaseClient get db => _client ?? Supabase.instance.client;
  bool get signedIn => db.auth.currentUser != null;
  String get userLabel => db.auth.currentUser?.email ?? 'Viewer';
  List<RecordData> channels = [], sections = [], videos = [], quizzes = [];
  List<RecordData> playlists = [], playlistVideos = [];
  bool loading = false;
  String? error;
  RealtimeChannel? subscription;
  StreamSubscription<AuthState>? authSubscription;
  Timer? retry;
  bool disposed = false;
  bool _refreshAgain = false;
  Completer<void>? _refreshComplete;
  VoidCallback? onAuthenticated;

  void _changed() {
    if (!disposed) notifyListeners();
  }

  Future<void> init() async {
    final cached = prefs.getString('catalog:$backendUrl');
    if (cached != null) {
      try {
        _assign(jsonDecode(cached) as RecordData);
      } catch (_) {
        /* Ignore invalid cached catalog data. */
      }
    }
    if (disposed) return;
    authSubscription = db.auth.onAuthStateChange.listen((event) {
      if (disposed) return;
      _changed();
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
      if (disposed) return;
      if (status == RealtimeSubscribeStatus.subscribed) unawaited(refresh());
      if (status == RealtimeSubscribeStatus.channelError ||
          status == RealtimeSubscribeStatus.timedOut) {
        error = 'Live updates interrupted. Pull to refresh; reconnecting…';
        _changed();
      }
    });
    retry = Timer.periodic(const Duration(seconds: 45), (_) => refresh());
    await refresh();
  }

  void _assign(RecordData data) {
    final newChannels = List<RecordData>.from(data['channels']);
    final channelIds = newChannels.map((c) => c['id']).toSet();
    final newSections = List<RecordData>.from(
      data['sections'],
    ).where((s) => channelIds.contains(s['channel_id'])).toList();
    final sectionIds = newSections.map((s) => s['id']).toSet();
    final newVideos = List<RecordData>.from(data['videos'])
        .where(
          (v) =>
              channelIds.contains(v['channel_id']) &&
              sectionIds.contains(v['section_id']),
        )
        .toList();
    final videoIds = newVideos.map((v) => v['id']).toSet();
    final newQuizzes = List<RecordData>.from(
      data['quizzes'],
    ).where((q) => videoIds.contains(q['video_id'])).toList();
    channels = newChannels;
    sections = newSections;
    videos = newVideos;
    quizzes = newQuizzes;
    playlists = List<RecordData>.from(
      data['playlists'] ?? [],
    ).where((p) => channelIds.contains(p['channel_id'])).toList();
    final playlistIds = playlists.map((p) => p['id']).toSet();
    playlistVideos = List<RecordData>.from(data['playlist_videos'] ?? [])
        .where(
          (p) =>
              playlistIds.contains(p['playlist_id']) &&
              videoIds.contains(p['video_id']),
        )
        .toList();
  }

  Future<List<RecordData>> _catalogRows(
    String table,
    String column,
    Object value,
    String order, {
    bool ascending = true,
  }) async {
    const pageSize = 500;
    final all = <RecordData>[];
    for (var offset = 0; ; offset += pageSize) {
      final page = List<RecordData>.from(
        await db
            .from(table)
            .select()
            .eq(column, value)
            .order(order, ascending: ascending)
            .order('id')
            .range(offset, offset + pageSize - 1),
      );
      all.addAll(page);
      if (page.length < pageSize) return all;
    }
  }

  /// YouTube upload time wins; older catalogs retain their publication ordering.
  static DateTime uploadTime(RecordData video) =>
      DateTime.tryParse(
        '${video['youtube_published_at'] ?? video['published_at'] ?? ''}',
      ) ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  List<RecordData> channelUploads(
    String? channelId, {
    String? playlistId,
    String? sectionId,
  }) {
    final members = playlistVideos
        .where((p) => p['playlist_id'] == playlistId)
        .map((p) => p['video_id'])
        .toSet();
    final result = videos
        .where(
          (v) =>
              v['channel_id'] == channelId &&
              (playlistId == null || members.contains(v['id'])) &&
              (sectionId == null || v['section_id'] == sectionId),
        )
        .toList();
    result.sort((a, b) {
      final order = uploadTime(b).compareTo(uploadTime(a));
      return order != 0 ? order : '${a['id']}'.compareTo('${b['id']}');
    });
    return result;
  }

  List<RecordData> popularUploads(String? channelId) {
    final result = channelUploads(
      channelId,
    ).where((v) => v['view_count'] is num).toList();
    result.sort((a, b) {
      final order = (b['view_count'] as num).compareTo(a['view_count'] as num);
      return order != 0 ? order : uploadTime(b).compareTo(uploadTime(a));
    });
    return result;
  }

  Future<List<RecordData>> _optionalPlaylistRows(String table) async {
    try {
      if (table == 'playlists') {
        return await _catalogRows(table, 'active', true, 'position');
      }
      final rows = <RecordData>[];
      for (var offset = 0; ; offset += 500) {
        final page = List<RecordData>.from(
          await db
              .from(table)
              .select()
              .order('playlist_id')
              .order('video_id')
              .range(offset, offset + 499),
        );
        rows.addAll(page);
        if (page.length < 500) return rows;
      }
    } on PostgrestException catch (e) {
      // Compatibility with installations that have not applied migration 005.
      if ({'PGRST205', '42P01'}.contains(e.code)) return [];
      rethrow;
    }
  }

  Future<void> refresh() async {
    if (disposed) return;
    if (loading) {
      _refreshAgain = true;
      await _refreshComplete?.future;
      return;
    }
    final complete = Completer<void>();
    _refreshComplete = complete;
    loading = true;
    error = null;
    _changed();
    try {
      final results = await Future.wait([
        _catalogRows('channels', 'active', true, 'position'),
        _catalogRows('sections', 'active', true, 'position'),
        _catalogRows(
          'videos',
          'status',
          'published',
          'published_at',
          ascending: false,
        ),
        _catalogRows('quizzes', 'status', 'published', 'created_at'),
        _optionalPlaylistRows('playlists'),
        _optionalPlaylistRows('playlist_videos'),
      ]).timeout(const Duration(seconds: 20));
      if (disposed) return;
      _assign({
        'channels': results[0],
        'sections': results[1],
        'videos': results[2],
        'quizzes': results[3],
        'playlists': results[4],
        'playlist_videos': results[5],
      });
      await prefs.setString(
        'catalog:$backendUrl',
        jsonEncode({
          'channels': channels,
          'sections': sections,
          'videos': videos,
          'quizzes': quizzes,
          'playlists': playlists,
          'playlist_videos': playlistVideos,
        }),
      );
    } on PostgrestException catch (exception) {
      error = {'PGRST205', '42P01'}.contains(exception.code)
          ? 'The channel library is still being set up. Please try again later.'
          : 'Can’t reach CURLYmax. Check your connection and try again. Saved catalog may be out of date.';
    } catch (_) {
      error =
          'Can’t reach CURLYmax. Check your connection and try again. Saved catalog may be out of date.';
    } finally {
      loading = false;
      _changed();
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
  Future<void> signInWithEmail(String email, String password) async {
    await db.auth.signInWithPassword(email: email.trim(), password: password);
  }

  Future<bool> createAccount(String email, String password) async {
    final response = await db.auth.signUp(
      email: email.trim(),
      password: password,
      emailRedirectTo: AppConfig.authRedirect,
    );
    return response.session != null;
  }

  Future<void> signInWithGoogle() async {
    if (!await db.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: AppConfig.authRedirect,
    )) {
      throw StateError('The sign-in browser could not be opened.');
    }
  }

  Future<void> signOut() async {
    await db.auth.signOut();
    await clearPending();
    _changed();
  }

  Future<void> deleteAccount() async {
    _requireSignIn();
    try {
      final response = await db.functions
          .invoke('delete-account', body: {'confirmation': 'DELETE'})
          .timeout(const Duration(seconds: 30));
      if (response.data is! Map || response.data['deleted'] != true) {
        throw StateError('The server did not confirm account deletion.');
      }
    } on FunctionException catch (error) {
      final details = error.details;
      if (details is Map && details['code'] == 'recent_sign_in_required') {
        throw StateError(
          'Sign out and sign in again, then delete your account within 15 minutes.',
        );
      }
      throw StateError(
        'Account deletion was not confirmed. Check your connection and try signing in again.',
      );
    }
    // Auth removes the local session before its sign-out HTTP request. That
    // request may fail because the server account has just been deleted.
    try {
      await db.auth
          .signOut(scope: SignOutScope.local)
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      /* A deleted account no longer has a refresh session to revoke. */
    }
    await prefs.clear();
    _changed();
  }

  void _requireSignIn() {
    if (!signedIn) throw StateError('Sign in required');
  }

  Future<List<RecordData>> notes(String video) async {
    _requireSignIn();
    return List<RecordData>.from(
      await db
          .from('notes')
          .select()
          .eq('video_id', video)
          .order('updated_at', ascending: false)
          .timeout(const Duration(seconds: 20)),
    );
  }

  Future<void> saveNote(String video, String body, {String? id}) async {
    _requireSignIn();
    if (body.trim().isEmpty || body.length > 20000) {
      throw ArgumentError('Enter a note of 1–20,000 characters.');
    }
    if (id == null) {
      await db
          .from('notes')
          .insert({'video_id': video, 'body': body.trim()})
          .timeout(const Duration(seconds: 20));
    } else {
      final changed = await db
          .from('notes')
          .update({
            'body': body.trim(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', id)
          .eq('video_id', video)
          .select('id')
          .timeout(const Duration(seconds: 20));
      if (changed.isEmpty) {
        throw StateError(
          'This note is no longer available. Refresh and try again.',
        );
      }
    }
  }

  Future<void> deleteNote(String id) async {
    _requireSignIn();
    await db
        .from('notes')
        .delete()
        .eq('id', id)
        .timeout(const Duration(seconds: 20));
  }

  Future<List<RecordData>> questions(String quiz) async {
    _requireSignIn();
    return List<RecordData>.from(
      await db
          .from('questions')
          .select('id,prompt,options,position')
          .eq('quiz_id', quiz)
          .order('position')
          .timeout(const Duration(seconds: 20)),
    );
  }

  Future<RecordData> submit(String quiz, Map<String, int> answers) async {
    _requireSignIn();
    return Map<String, dynamic>.from(
      await db
          .rpc('submit_quiz', params: {'quiz': quiz, 'answers': answers})
          .timeout(const Duration(seconds: 20)),
    );
  }

  Future<RecordData> startQuizRun(String quiz) async {
    _requireSignIn();
    return Map<String, dynamic>.from(
      await db
          .rpc('start_quiz_run', params: {'quiz': quiz})
          .timeout(const Duration(seconds: 20)),
    );
  }

  Future<RecordData> answerQuizQuestion(
    String run,
    String question,
    int choice,
  ) async {
    _requireSignIn();
    return Map<String, dynamic>.from(
      await db
          .rpc(
            'answer_quiz_question',
            params: {'run_id': run, 'question': question, 'choice': choice},
          )
          .timeout(const Duration(seconds: 20)),
    );
  }

  Future<List<RecordData>> attempts() async {
    _requireSignIn();
    return List<RecordData>.from(
      await db
          .from('attempts')
          .select()
          .order('submitted_at', ascending: false)
          .timeout(const Duration(seconds: 20)),
    );
  }

  @override
  void dispose() {
    disposed = true;
    retry?.cancel();
    unawaited(authSubscription?.cancel());
    if (subscription != null) unawaited(db.removeChannel(subscription!));
    super.dispose();
  }
}
