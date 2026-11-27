import 'dart:async';
import 'dart:convert';
import 'youtube_workspace.dart';
import 'quiz_import.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef RecordData = Map<String, dynamic>;
const tables = [
  'channels',
  'sections',
  'videos',
  'quizzes',
  'Notifications',
  'playlists',
  'YouTube',
];
const navigationLabels = [
  'Channels',
  'Sections',
  'Videos',
  'Quizzes',
  'Alerts',
  'Playlists',
  'YouTube',
];
const navigationIcons = [
  Icons.tv,
  Icons.folder,
  Icons.play_circle,
  Icons.quiz,
  Icons.notifications,
  Icons.playlist_play,
  Icons.sync,
];
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('SUPABASE_URL');
  const key = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: String.fromEnvironment('SUPABASE_ANON_KEY'),
  );
  String? error;
  try {
    if (!isValidProjectUrl(url) || !isPublicKey(key)) {
      throw StateError(
        'Set a Supabase HTTPS URL and public publishable key in dashboard/config.json.',
      );
    }
    await Supabase.initialize(
      url: url,
      publishableKey: key,
      authOptions: FlutterAuthClientOptions(
        persistSession: kIsWeb,
        detectSessionInUriPredicate: (uri) => kIsWeb
            ? uri.origin == Uri.base.origin
            : uri.scheme == 'com.curlymax.studio' &&
                  uri.host == 'login-callback',
      ),
    );
  } catch (_) {
    error =
        'Unable to initialize Studio. Check the public Supabase configuration and restart.';
  }
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CURLYmax Studio',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xffc5f35b),
        scaffoldBackgroundColor: const Color(0xff101410),
      ),
      home: error == null
          ? const Studio()
          : Scaffold(body: Center(child: Text(error))),
    ),
  );
}

bool isValidProjectUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      (uri.path.isEmpty || uri.path == '/');
}

bool isPublicKey(String key) {
  if (key.startsWith('sb_publishable_')) return key.length > 20;
  final parts = key.split('.');
  if (parts.length != 3 || parts.any((part) => part.isEmpty)) return false;
  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(key.split('.')[1]))),
    );
    return payload is Map && payload['role'] == 'anon';
  } catch (_) {
    return false;
  }
}

class Studio extends StatefulWidget {
  const Studio({super.key, this.client, this.realtimeEnabled = true});
  final SupabaseClient? client;
  final bool realtimeEnabled;
  @override
  State<Studio> createState() => _StudioState();
}

class _StudioState extends State<Studio> with WidgetsBindingObserver {
  late final db = widget.client ?? Supabase.instance.client;
  final email = TextEditingController(), password = TextEditingController();
  StreamSubscription<AuthState>? auth;
  RealtimeChannel? catalogChannel;
  Timer? refreshTimer, recoveryTimer;
  bool refreshRunning = false, refreshAgain = false;
  bool foreground = true;

  bool currentOwner(int generation) =>
      mounted &&
      owner &&
      foreground &&
      generation == authGeneration &&
      db.auth.currentUser != null;

  void stopUpdates() {
    refreshTimer?.cancel();
    recoveryTimer?.cancel();
    refreshAgain = false;
    final channel = catalogChannel;
    catalogChannel = null;
    if (channel != null) unawaited(db.removeChannel(channel));
  }

  void queueRefresh() {
    if (!currentOwner(authGeneration) || busy) return;
    refreshTimer?.cancel();
    refreshTimer = Timer(const Duration(milliseconds: 300), () {
      if (currentOwner(authGeneration)) unawaited(refresh());
    });
  }

  void startUpdates(int generation) {
    if (!currentOwner(generation)) return;
    if (!widget.realtimeEnabled) return;
    final channel = db.channel('studio-catalog-$generation');
    catalogChannel = channel;
    for (final table in [
      'channels',
      'sections',
      'videos',
      'quizzes',
      'playlists',
      'playlist_videos',
    ]) {
      channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        callback: (_) {
          if (currentOwner(generation)) queueRefresh();
        },
      );
    }
    channel.subscribe((status, error) {
      if (status == RealtimeSubscribeStatus.subscribed &&
          currentOwner(generation)) {
        queueRefresh();
      }
    });
    // Recover missed websocket events and refresh private notification status.
    recoveryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (currentOwner(generation)) queueRefresh();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) {
      unawaited(checkOwner());
    } else {
      stopUpdates();
    }
  }

  bool checking = true, owner = false, busy = false, ownerChecked = false;
  String? error;
  int selected = 0;
  int authGeneration = 0;
  String search = '';
  Map<String, List<RecordData>> data = {};
  List<RecordData> notifications = [];
  String get table => tables[selected];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    auth = db.auth.onAuthStateChange.listen((event) {
      if (event.event == AuthChangeEvent.tokenRefreshed && owner) {
        queueRefresh();
      } else {
        if (db.auth.currentUser == null && mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
        unawaited(checkOwner());
      }
    });
    checkOwner();
  }

  @override
  void dispose() {
    ++authGeneration;
    stopUpdates();
    WidgetsBinding.instance.removeObserver(this);
    auth?.cancel();
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> checkOwner() async {
    if (!mounted) return;
    final generation = ++authGeneration;
    stopUpdates();
    setState(() {
      checking = true;
      busy = false;
      owner = false;
      ownerChecked = false;
      data = {};
      notifications = [];
      error = null;
    });
    try {
      final allowed =
          db.auth.currentUser != null &&
          await db.rpc('is_owner').timeout(const Duration(seconds: 20)) == true;
      if (!mounted || generation != authGeneration) return;
      setState(() {
        owner = allowed;
        ownerChecked = true;
        checking = false;
        data = {};
        notifications = [];
      });
      if (!allowed) Navigator.of(context).popUntil((route) => route.isFirst);
      if (allowed) {
        startUpdates(generation);
        await refresh();
      }
    } catch (e) {
      if (mounted && generation == authGeneration) {
        setState(() {
          error =
              'Could not verify owner access. Check your connection and try again.';
          checking = false;
          owner = false;
        });
      }
    }
  }

  Future<void> refresh() async {
    if (!currentOwner(authGeneration)) return;
    if (refreshRunning) {
      refreshAgain = true;
      return;
    }
    refreshRunning = true;
    final generation = authGeneration;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final loaded = <String, List<RecordData>>{};
      for (final t in [
        'channels',
        'sections',
        'videos',
        'quizzes',
        'playlists',
      ]) {
        final rows = <RecordData>[];
        for (var start = 0; ; start += 500) {
          if (!currentOwner(generation)) return;
          List<RecordData> page;
          try {
            page = List<RecordData>.from(
              await db
                  .from(t)
                  .select()
                  .order('id')
                  .range(start, start + 499)
                  .timeout(const Duration(seconds: 20)),
            );
          } catch (_) {
            if (t != 'playlists') rethrow;
            if (currentOwner(generation)) {
              setState(
                () => error =
                    'Playlists could not load. Other catalog content is available; refresh to retry.',
              );
            }
            break;
          }
          rows.addAll(page);
          if (page.length < 500) break;
        }
        loaded[t] = rows;
      }
      if (!currentOwner(generation)) return;
      setState(() => data = loaded);
      final events = List<RecordData>.from(
        await db
            .rpc('owner_notification_status')
            .timeout(const Duration(seconds: 20)),
      );
      if (currentOwner(generation)) {
        setState(() => notifications = events);
      }
    } catch (e) {
      if (currentOwner(generation)) setState(() => error = '$e');
    } finally {
      refreshRunning = false;
      if (mounted && generation == authGeneration) setState(() => busy = false);
      if (refreshAgain) {
        refreshAgain = false;
        queueRefresh();
      }
    }
  }

  Future<void> act(Future<void> Function() action) async {
    if (!owner || db.auth.currentUser == null || busy) return;
    final generation = authGeneration;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      await refresh();
    } catch (e) {
      if (currentOwner(generation)) setState(() => error = '$e');
    } finally {
      if (mounted && generation == authGeneration) setState(() => busy = false);
    }
  }

  String label(String t, dynamic id) {
    for (final r in data[t] ?? <RecordData>[]) {
      if (r['id'] == id) return '${r['title'] ?? r['name']}';
    }
    return '$id';
  }

  Future<void> remove(RecordData row) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Permanently delete?'),
        content: Text(
          '${row['title'] ?? row['name']}\n\nReferenced content cannot be deleted. Unpublish or deactivate it instead to preserve viewer records.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes == true) {
      final t = table;
      await act(() async {
        await db.from(t).delete().eq('id', row['id']);
      });
    }
  }

  Future<void> edit([RecordData? row]) async {
    final t = table;
    final result = await showDialog<RecordData>(
      context: context,
      builder: (_) => ContentForm(table: t, row: row, data: data),
    );
    if (result == null) return;
    await act(() async {
      if (row == null && t == 'quizzes') {
        await db.rpc(
          'owner_create_quiz',
          params: {
            'video_id': result['video_id'],
            'title': result['title'],
            'question': result['question'],
          },
        );
      } else if (row == null) {
        await db.from(t).insert(result);
      } else {
        await db.from(t).update(result).eq('id', row['id']);
      }
    });
  }

  Future<void> importQuiz() async {
    final generation = authGeneration;
    if (!currentOwner(generation)) return;
    final uploaded = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => QuizImportDialog(
        videos: data['videos'] ?? <RecordData>[],
        upload: (videoId, quiz) async {
          if (!currentOwner(generation)) throw StateError('Sign in again.');
          await db
              .rpc(
                'owner_import_quiz',
                params: {
                  'video_id': videoId,
                  'title': quiz['title'],
                  'items': quiz['questions'],
                },
              )
              .timeout(const Duration(seconds: 30));
        },
      ),
    );
    if (mounted && currentOwner(generation) && uploaded == true) {
      await refresh();
    }
  }

  Future<void> questions(RecordData row) async {
    final generation = authGeneration;
    if (!currentOwner(generation)) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final items = List<RecordData>.from(
        await db.rpc('owner_quiz_questions', params: {'target': row['id']}),
      );
      if (!mounted || !currentOwner(generation)) return;
      await showDialog<void>(
        context: context,
        builder: (_) => QuestionEditor(db: db, quiz: row, items: items),
      );
    } catch (e) {
      if (currentOwner(generation)) setState(() => error = '$e');
    } finally {
      if (mounted && generation == authGeneration) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!owner) {
      return Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 48),
          child: Center(
            child: SizedBox(
              width: 440,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'CURLYmax Studio',
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text('Owner control dashboard'),
                      if (!kIsWeb)
                        const Text(
                          'For your security, sign in again after closing the app.',
                        ),
                      if (db.auth.currentUser == null) ...[
                        const SizedBox(height: 24),
                        TextField(
                          controller: email,
                          decoration: const InputDecoration(
                            labelText: 'Owner email',
                          ),
                        ),
                        TextField(
                          controller: password,
                          obscureText: true,
                          onSubmitted: (_) => login(),
                          decoration: const InputDecoration(
                            labelText: 'Password',
                          ),
                        ),
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: busy ? null : login,
                          child: const Text('Sign in'),
                        ),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  try {
                                    await db.auth.signInWithOAuth(
                                      OAuthProvider.google,
                                      redirectTo: kIsWeb
                                          ? Uri.base.origin
                                          : 'com.curlymax.studio://login-callback/',
                                    );
                                  } catch (e) {
                                    if (mounted) setState(() => error = '$e');
                                  }
                                },
                          child: const Text('Continue with Google'),
                        ),
                      ] else ...[
                        const SizedBox(height: 20),
                        SelectableText(
                          ownerChecked
                              ? 'This account is not an owner.\nUser ID: ${db.auth.currentUser!.id}\n\nFollow README.md to grant your account owner access.'
                              : 'Owner access could not be verified. Retry when your connection is available.',
                        ),
                        TextButton(
                          onPressed: checkOwner,
                          child: const Text('Check access again'),
                        ),
                        TextButton(
                          onPressed: () => db.auth.signOut(),
                          child: const Text('Sign out'),
                        ),
                      ],
                      if (error != null)
                        SelectableText(
                          error!,
                          style: const TextStyle(color: Colors.orangeAccent),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    final compact = MediaQuery.sizeOf(context).width < 700;
    final rows =
        (table == 'Notifications'
                ? notifications
                : data[table] ?? <RecordData>[])
            .where(
              (r) =>
                  '${r['title'] ?? r['name'] ?? ''} ${r['handle'] ?? ''} ${r['status'] ?? r['state'] ?? ''}'
                      .toLowerCase()
                      .contains(search.toLowerCase()),
            )
            .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('CURLYmax Studio'),
        actions: [
          if (table == 'quizzes')
            IconButton(
              onPressed: busy ? null : importQuiz,
              icon: const Icon(Icons.upload_file),
              tooltip: 'Import quiz JSON',
            ),
          IconButton(
            onPressed: busy ? null : refresh,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
          IconButton(
            onPressed: () => db.auth.signOut(),
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
          ),
        ],
      ),
      drawer: compact
          ? Drawer(
              child: SafeArea(
                child: ListView(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Creator workspace',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    for (var i = 0; i < tables.length; i++)
                      ListTile(
                        selected: selected == i,
                        leading: Icon(navigationIcons[i]),
                        title: Text(navigationLabels[i]),
                        onTap: () {
                          setState(() {
                            selected = i;
                            search = '';
                          });
                          Navigator.pop(context);
                        },
                      ),
                  ],
                ),
              ),
            )
          : null,
      body: SafeArea(
        child: Row(
          children: [
            if (!compact)
              NavigationRail(
                selectedIndex: selected,
                labelType: NavigationRailLabelType.all,
                onDestinationSelected: busy
                    ? null
                    : (i) => setState(() {
                        selected = i;
                        search = '';
                      }),
                destinations: [
                  for (var i = 0; i < tables.length; i++)
                    NavigationRailDestination(
                      icon: Icon(navigationIcons[i]),
                      label: Text(navigationLabels[i]),
                    ),
                ],
              ),
            if (!compact) const VerticalDivider(width: 1),
            Expanded(
              child: table == 'YouTube'
                  ? YoutubeWorkspace(
                      db: db,
                      channels: data['channels'] ?? [],
                      sections: data['sections'] ?? [],
                      onChanged: refresh,
                    )
                  : Padding(
                      padding: EdgeInsets.all(compact ? 12 : 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                '${navigationLabels[selected]} · ${rows.length}',
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineMedium,
                              ),
                              if (table != 'Notifications')
                                FilledButton.icon(
                                  onPressed: busy ? null : () => edit(),
                                  icon: const Icon(Icons.add),
                                  label: const Text('Add new'),
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          if (table == 'videos' || table == 'quizzes')
                            Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  Chip(
                                    avatar: const Icon(
                                      Icons.edit_note,
                                      size: 18,
                                    ),
                                    label: Text(
                                      '${(data[table] ?? []).where((r) => r['status'] == 'draft').length} drafts to review',
                                    ),
                                  ),
                                  Chip(
                                    avatar: const Icon(Icons.public, size: 18),
                                    label: Text(
                                      '${(data[table] ?? []).where((r) => r['status'] == 'published').length} published',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          TextField(
                            key: ValueKey(table),
                            onChanged: (v) => setState(() => search = v),
                            decoration: const InputDecoration(
                              prefixIcon: Icon(Icons.search),
                              labelText: 'Search title, name, or status',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          if (busy) const LinearProgressIndicator(),
                          if (error != null)
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: SelectableText(
                                'Could not complete request: $error',
                                style: const TextStyle(
                                  color: Colors.orangeAccent,
                                ),
                              ),
                            ),
                          if (table == 'Notifications')
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Text(
                                'Last 100 publication events. Pending alerts need the server sender. Failed or dispatching events require review; sending is not retried here.',
                              ),
                            ),
                          Expanded(
                            child: rows.isEmpty
                                ? Center(
                                    child: Text(
                                      busy
                                          ? 'Loading…'
                                          : 'No items. Add content or change your search.',
                                    ),
                                  )
                                : ListView.builder(
                                    itemCount: rows.length,
                                    itemBuilder: (_, i) {
                                      final r = rows[i];
                                      final sub = table == 'videos'
                                          ? '${label('channels', r['channel_id'])} / ${label('sections', r['section_id'])}\n${r['youtube_url']}\n${r['status']}'
                                          : table == 'quizzes'
                                          ? '${label('videos', r['video_id'])}\n${r['status']}'
                                          : table == 'sections'
                                          ? '${label('channels', r['channel_id'])} · ${r['active'] == true ? 'Active' : 'Hidden'}'
                                          : table == 'channels'
                                          ? '${r['handle']} · ${r['active'] == true ? 'Active' : 'Hidden'}'
                                          : '${r['kind']} · ${r['state']} · ${r['created_at']}\n${r['detail'] ?? ''}';
                                      return Card(
                                        child: Padding(
                                          padding: const EdgeInsets.all(16),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '${r['title'] ?? r['name']}',
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.titleLarge,
                                              ),
                                              const SizedBox(height: 8),
                                              SelectableText(sub),
                                              if (table != 'Notifications')
                                                Wrap(
                                                  spacing: 8,
                                                  children: [
                                                    TextButton.icon(
                                                      onPressed: busy
                                                          ? null
                                                          : () => edit(r),
                                                      icon: const Icon(
                                                        Icons.edit,
                                                      ),
                                                      label: const Text('Edit'),
                                                    ),
                                                    if (table == 'quizzes')
                                                      TextButton.icon(
                                                        onPressed: busy
                                                            ? null
                                                            : () =>
                                                                  questions(r),
                                                        icon: const Icon(
                                                          Icons.checklist,
                                                        ),
                                                        label: const Text(
                                                          'Questions & answers',
                                                        ),
                                                      ),
                                                    TextButton.icon(
                                                      onPressed: busy
                                                          ? null
                                                          : () => remove(r),
                                                      icon: const Icon(
                                                        Icons.delete_outline,
                                                      ),
                                                      label: const Text(
                                                        'Delete',
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> login() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await db.auth
          .signInWithPassword(email: email.text.trim(), password: password.text)
          .timeout(const Duration(seconds: 20));
      password.clear();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

class ContentForm extends StatefulWidget {
  final String table;
  final RecordData? row;
  final Map<String, List<RecordData>> data;
  const ContentForm({
    super.key,
    required this.table,
    this.row,
    required this.data,
  });
  @override
  State<ContentForm> createState() => _ContentFormState();
}

class _ContentFormState extends State<ContentForm> {
  final form = GlobalKey<FormState>();
  final fields = <String, TextEditingController>{};
  String? channel, section, video;
  int? firstCorrect;
  bool active = true;
  bool syncManaged = false;
  String status = 'draft';
  @override
  void initState() {
    super.initState();
    final r = widget.row ?? {};
    for (final k in [
      'prompt',
      'option1',
      'option2',
      'option3',
      'option4',
      'explanation',
      'name',
      'handle',
      'avatar_url',
      'title',
      'description',
      'youtube_url',
      'position',
      'youtube_playlist_id',
      'thumbnail_url',
    ]) {
      fields[k] = TextEditingController(
        text: '${r[k] ?? (k == 'position' ? 0 : '')}',
      );
    }
    channel = r['channel_id'];
    section = r['section_id'];
    video = r['video_id'];
    active = r['active'] ?? true;
    syncManaged = r['sync_managed'] == true;
    status = r['status'] ?? 'draft';
  }

  @override
  void dispose() {
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget field(
    String k,
    String title, {
    bool required = true,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      controller: fields[k],
      maxLines: lines,
      decoration: InputDecoration(
        labelText: title,
        border: const OutlineInputBorder(),
      ),
      validator: (v) {
        if (required && (v == null || v.trim().isEmpty)) return 'Required';
        if (k == 'position' && int.tryParse(v ?? '') == null) {
          return 'Enter a whole number';
        }
        if (k == 'youtube_playlist_id' &&
            !RegExp(r'^[A-Za-z0-9_-]{10,100}$').hasMatch(v ?? '')) {
          return 'Enter the playlist ID, not its URL';
        }
        if ((k == 'thumbnail_url' || k == 'avatar_url') &&
            (v?.isNotEmpty ?? false) &&
            Uri.tryParse(v!)?.scheme != 'https') {
          return 'Use an HTTPS image URL';
        }
        if (k == 'youtube_url' &&
            !RegExp(
              r'^https?://(?:(?:www\.|m\.)?youtube\.com/(?:watch\?.*\bv=|shorts/)|youtu\.be/)[A-Za-z0-9_-]{11}(?:[?&#/].*)?$',
            ).hasMatch(v ?? '')) {
          return 'Use a YouTube watch, Shorts or youtu.be URL';
        }
        return null;
      },
    ),
  );
  Widget pick(
    String title,
    String? value,
    List<RecordData> rows,
    void Function(String?) changed,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: title,
        border: const OutlineInputBorder(),
      ),
      items: rows
          .map(
            (r) => DropdownMenuItem(
              value: '${r['id']}',
              child: Text(
                '${r['name'] ?? r['title']}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(),
      onChanged: changed,
      validator: (v) => v == null ? 'Choose $title' : null,
    ),
  );
  @override
  Widget build(BuildContext context) {
    final t = widget.table;
    return AlertDialog(
      title: Text('${widget.row == null ? 'Add' : 'Edit'} $t'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (t == 'channels' || t == 'sections') field('name', 'Name'),
                if (t == 'channels') ...[
                  field('handle', 'YouTube handle, e.g. @ashiy_ish'),
                  field(
                    'avatar_url',
                    'Channel icon HTTPS URL (optional)',
                    required: false,
                  ),
                ],
                if (t == 'sections' || t == 'videos' || t == 'playlists')
                  pick(
                    'Channel',
                    channel,
                    widget.data['channels'] ?? [],
                    (v) => setState(() {
                      channel = v;
                      section = null;
                    }),
                  ),
                if (t == 'videos')
                  KeyedSubtree(
                    key: ValueKey(channel),
                    child: pick(
                      'Section',
                      section,
                      (widget.data['sections'] ?? [])
                          .where((s) => s['channel_id'] == channel)
                          .toList(),
                      (v) => setState(() => section = v),
                    ),
                  ),
                if (t == 'quizzes')
                  pick(
                    'Video',
                    video,
                    widget.data['videos'] ?? [],
                    (v) => setState(() => video = v),
                  ),
                if (t == 'videos' || t == 'quizzes' || t == 'playlists')
                  field('title', t == 'quizzes' ? 'Quiz title' : 'Title'),
                if (t == 'quizzes' && widget.row == null) ...[
                  field(
                    'prompt',
                    'First question (optional; uses quiz title)',
                    required: false,
                  ),
                  for (var i = 1; i <= 4; i++)
                    field(
                      'option$i',
                      'Answer option $i${i > 2 ? ' (optional)' : ''}',
                      required: i <= 2,
                    ),
                  DropdownButtonFormField<int>(
                    initialValue: firstCorrect,
                    decoration: const InputDecoration(
                      labelText: 'Correct answer (required)',
                    ),
                    items: List.generate(
                      4,
                      (i) => DropdownMenuItem(
                        value: i,
                        child: Text('Answer option ${i + 1}'),
                      ),
                    ),
                    onChanged: (v) => firstCorrect = v,
                    validator: (v) =>
                        v == null ||
                            fields['option${v + 1}']!.text.trim().isEmpty
                        ? 'Choose a non-empty correct answer'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  field(
                    'explanation',
                    'Explanation (optional)',
                    required: false,
                    lines: 3,
                  ),
                  const Text(
                    'Saved as a draft. Review your quiz, then publish it when ready.',
                  ),
                ],
                if (t == 'playlists') ...[
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text(
                      'When YouTube management is on, sync refreshes playlist membership. Your title, description, thumbnail, visibility and display order stay under your control.',
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('Manage this playlist from YouTube'),
                    value: syncManaged,
                    onChanged: (v) => setState(() => syncManaged = v),
                  ),
                  field('youtube_playlist_id', 'YouTube playlist ID'),
                  field('position', 'Sort position'),
                  field(
                    'description',
                    'Description',
                    required: false,
                    lines: 3,
                  ),
                  field(
                    'thumbnail_url',
                    'Thumbnail HTTPS URL',
                    required: false,
                  ),
                  SwitchListTile(
                    title: const Text('Active / visible'),
                    value: active,
                    onChanged: (v) => setState(() => active = v),
                  ),
                ],
                if (t == 'videos') ...[
                  field('youtube_url', 'YouTube URL'),
                  field(
                    'description',
                    'Description',
                    required: false,
                    lines: 4,
                  ),
                ],
                if (t == 'channels' || t == 'sections') ...[
                  field('position', 'Sort position'),
                  SwitchListTile(
                    title: const Text('Active / visible'),
                    value: active,
                    onChanged: (v) => setState(() => active = v),
                  ),
                ],
                if (t == 'videos' ||
                    (t == 'quizzes' && widget.row != null)) ...[
                  DropdownButtonFormField<String>(
                    initialValue: status,
                    decoration: const InputDecoration(
                      labelText: 'Publication status',
                    ),
                    items: ['draft', 'published']
                        .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                        .toList(),
                    onChanged: (v) => setState(() => status = v!),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Publishing creates a notification event the first time. Quizzes need a published video and valid questions/answers. Save a new quiz as a draft first. Unpublish quizzes before changing questions.',
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!form.currentState!.validate()) return;
            final r = <String, dynamic>{};
            for (final k
                in (t == 'channels'
                    ? ['name', 'handle', 'avatar_url']
                    : t == 'sections'
                    ? ['name']
                    : t == 'videos'
                    ? ['title', 'youtube_url', 'description']
                    : t == 'playlists'
                    ? [
                        'title',
                        'youtube_playlist_id',
                        'description',
                        'thumbnail_url',
                      ]
                    : ['title'])) {
              r[k] = fields[k]!.text.trim();
            }
            if (t == 'channels' && fields['avatar_url']!.text.trim().isEmpty) {
              r['avatar_url'] = null;
            }
            if (t == 'channels' || t == 'sections') {
              r['position'] = int.parse(fields['position']!.text);
              r['active'] = active;
            }
            if (t == 'sections' || t == 'videos' || t == 'playlists') {
              r['channel_id'] = channel;
            }
            if (t == 'videos') r['section_id'] = section;
            if (t == 'quizzes') r['video_id'] = video;
            if (t == 'quizzes' && widget.row == null) {
              final supplied = List.generate(
                4,
                (i) => fields['option${i + 1}']!.text.trim(),
              );
              final kept = [
                for (var i = 0; i < 4; i++)
                  if (supplied[i].isNotEmpty) i,
              ];
              r['question'] = {
                'prompt': fields['prompt']!.text.trim().isEmpty
                    ? fields['title']!.text.trim()
                    : fields['prompt']!.text.trim(),
                'options': [for (final i in kept) supplied[i]],
                'correct_index': kept.indexOf(firstCorrect!),
                'explanation': fields['explanation']!.text.trim(),
              };
            }
            if (t == 'playlists') {
              r['sync_managed'] = syncManaged;
              r['active'] = active;
              r['position'] = int.parse(fields['position']!.text);
            }
            if (t == 'videos' || t == 'quizzes') r['status'] = status;
            Navigator.pop(context, r);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class QuestionEditor extends StatefulWidget {
  final SupabaseClient db;
  final RecordData quiz;
  final List<RecordData> items;
  const QuestionEditor({
    super.key,
    required this.db,
    required this.quiz,
    required this.items,
  });
  @override
  State<QuestionEditor> createState() => _QuestionEditorState();
}

class _QuestionEditorState extends State<QuestionEditor> {
  late final List<RecordData> items = widget.items
      .map((q) => Map<String, dynamic>.from(q))
      .toList();
  bool saving = false;
  String? error;
  bool get editable => widget.quiz['status'] == 'draft';
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Questions · ${widget.quiz['title']}'),
    content: SizedBox(
      width: 700,
      height: MediaQuery.sizeOf(context).height * .65,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            editable
                ? 'Use 2–4 options and choose the correct answer. Existing 5–6 option questions are preserved; you cannot add more options to them.'
                : 'Published quiz: read only. Close and change its status to draft to edit.',
          ),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.orangeAccent)),
          Expanded(
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (_, i) {
                final q = items[i];
                final choices = List<String>.from(q['options']);
                return Card(
                  key: ObjectKey(q),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        TextFormField(
                          initialValue: q['prompt'],
                          enabled: editable && !saving,
                          decoration: InputDecoration(
                            labelText: 'Question ${i + 1}',
                          ),
                          onChanged: (v) => q['prompt'] = v,
                        ),
                        TextFormField(
                          initialValue: q['explanation'] ?? '',
                          enabled: editable && !saving,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            labelText:
                                'Why this answer? (optional explanation)',
                          ),
                          onChanged: (v) => q['explanation'] = v,
                        ),
                        for (var j = 0; j < choices.length; j++)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: TextFormField(
                              initialValue: choices[j],
                              enabled: editable && !saving,
                              decoration: InputDecoration(
                                labelText: 'Option ${j + 1}',
                              ),
                              onChanged: (v) {
                                final a = List<String>.from(q['options']);
                                a[j] = v;
                                q['options'] = a;
                              },
                            ),
                          ),
                        DropdownButtonFormField<int>(
                          key: ValueKey(
                            '${q['correct_index']}-${choices.length}',
                          ),
                          initialValue: q['correct_index'],
                          decoration: const InputDecoration(
                            labelText: 'Correct answer (required)',
                            hintText: 'Choose an option',
                          ),
                          items: List.generate(
                            choices.length,
                            (j) => DropdownMenuItem(
                              value: j,
                              child: Text('Option ${j + 1}'),
                            ),
                          ),
                          onChanged: editable && !saving
                              ? (v) => setState(() => q['correct_index'] = v)
                              : null,
                        ),
                        if (editable)
                          Wrap(
                            children: [
                              TextButton(
                                onPressed: saving || choices.length >= 4
                                    ? null
                                    : () => setState(
                                        () => q['options'] = [
                                          ...q['options'],
                                          '',
                                        ],
                                      ),
                                child: const Text('Add option'),
                              ),
                              TextButton(
                                onPressed: saving || choices.length <= 2
                                    ? null
                                    : () => setState(() {
                                        q['options'] = choices.sublist(
                                          0,
                                          choices.length - 1,
                                        );
                                        if ((q['correct_index'] ?? 0) >=
                                            choices.length - 1) {
                                          q['correct_index'] = null;
                                        }
                                      }),
                                child: const Text('Remove last option'),
                              ),
                              TextButton(
                                onPressed: saving
                                    ? null
                                    : () => setState(() => items.removeAt(i)),
                                child: const Text('Delete question'),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          if (editable)
            TextButton.icon(
              onPressed: saving
                  ? null
                  : () => setState(
                      () => items.add({
                        'prompt': '',
                        'options': ['', '', '', ''],
                        'correct_index': null,
                      }),
                    ),
              icon: const Icon(Icons.add),
              label: const Text('Add question'),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('Close'),
      ),
      if (editable)
        FilledButton(
          onPressed: saving
              ? null
              : () async {
                  if (items.any(
                    (q) =>
                        '${q['prompt']}'.trim().isEmpty ||
                        (q['options'] as List).any(
                          (o) => '$o'.trim().isEmpty,
                        ) ||
                        q['correct_index'] == null,
                  )) {
                    setState(
                      () => error =
                          'Complete every prompt, option and correct answer.',
                    );
                    return;
                  }
                  setState(() {
                    saving = true;
                    error = null;
                  });
                  try {
                    await widget.db.rpc(
                      'owner_save_questions',
                      params: {
                        'target': widget.quiz['id'],
                        'items': items
                            .map(
                              (q) => {
                                'prompt': q['prompt'],
                                'options': q['options'],
                                'correct_index': q['correct_index'],
                                'explanation': q['explanation'] ?? '',
                              },
                            )
                            .toList(),
                      },
                    );
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    if (mounted) setState(() => error = '$e');
                  } finally {
                    if (mounted) setState(() => saving = false);
                  }
                },
          child: Text(saving ? 'Saving…' : 'Save questions'),
        ),
    ],
  );
}
