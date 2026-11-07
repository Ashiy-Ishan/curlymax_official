import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef RecordData = Map<String, dynamic>;
const tables = ['channels', 'sections', 'videos', 'quizzes', 'Notifications'];
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('SUPABASE_URL');
  const key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  String? error;
  try {
    if (!url.startsWith('https://') ||
        key.isEmpty ||
        key.startsWith('sb_secret_')) {
      throw StateError(
        'Set a Supabase HTTPS URL and public publishable key in dashboard/config.json.',
      );
    }
    await Supabase.initialize(url: url, publishableKey: key);
  } catch (e) {
    error = '$e';
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

class Studio extends StatefulWidget {
  const Studio({super.key});
  @override
  State<Studio> createState() => _StudioState();
}

class _StudioState extends State<Studio> {
  final db = Supabase.instance.client;
  final email = TextEditingController(), password = TextEditingController();
  StreamSubscription<AuthState>? auth;
  bool checking = true, owner = false, busy = false;
  String? error;
  int selected = 0;
  String search = '';
  Map<String, List<RecordData>> data = {};
  List<RecordData> notifications = [];
  String get table => tables[selected];
  @override
  void initState() {
    super.initState();
    auth = db.auth.onAuthStateChange.listen((_) => checkOwner());
    checkOwner();
  }

  @override
  void dispose() {
    auth?.cancel();
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> checkOwner() async {
    if (!mounted) return;
    setState(() {
      checking = true;
      error = null;
    });
    try {
      final allowed =
          db.auth.currentUser != null && await db.rpc('is_owner') == true;
      if (!mounted) return;
      setState(() {
        owner = allowed;
        checking = false;
        data = {};
        notifications = [];
      });
      if (allowed) await refresh();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          checking = false;
          owner = false;
        });
      }
    }
  }

  Future<void> refresh() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final loaded = <String, List<RecordData>>{};
      for (final t in tables.take(4)) {
        final rows = <RecordData>[];
        for (var start = 0; ; start += 500) {
          final page = List<RecordData>.from(
            await db.from(t).select().order('id').range(start, start + 499),
          );
          rows.addAll(page);
          if (page.length < 500) break;
        }
        loaded[t] = rows;
      }
      if (mounted) setState(() => data = loaded);
      final events = List<RecordData>.from(
        await db.rpc('owner_notification_status'),
      );
      if (mounted) setState(() => notifications = events);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> act(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
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
      if (row == null) {
        await db.from(t).insert(result);
      } else {
        await db.from(t).update(result).eq('id', row['id']);
      }
    });
  }

  Future<void> questions(RecordData row) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final items = List<RecordData>.from(
        await db.rpc('owner_quiz_questions', params: {'target': row['id']}),
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => QuestionEditor(db: db, quiz: row, items: items),
      );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!owner) {
      return Scaffold(
        body: Center(
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
                                    redirectTo: Uri.base.origin,
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
                        'This account is not an owner.\nUser ID: ${db.auth.currentUser!.id}\n\nFollow README.md to grant your account owner access.',
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
      );
    }
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
          TextButton.icon(
            onPressed: busy ? null : refresh,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
          TextButton(
            onPressed: () => db.auth.signOut(),
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: selected,
            labelType: NavigationRailLabelType.all,
            onDestinationSelected: busy
                ? null
                : (i) => setState(() {
                    selected = i;
                    search = '';
                  }),
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.tv),
                label: Text('Channels'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.folder),
                label: Text('Sections'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.play_circle),
                label: Text('Videos'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.quiz),
                label: Text('Quizzes'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.notifications),
                label: Text('Alerts'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '$table · ${rows.length}',
                        style: Theme.of(context).textTheme.headlineMedium,
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
                        style: const TextStyle(color: Colors.orangeAccent),
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
                                              icon: const Icon(Icons.edit),
                                              label: const Text('Edit'),
                                            ),
                                            if (table == 'quizzes')
                                              TextButton.icon(
                                                onPressed: busy
                                                    ? null
                                                    : () => questions(r),
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
                                              label: const Text('Delete'),
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
    );
  }

  Future<void> login() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await db.auth.signInWithPassword(
        email: email.text.trim(),
        password: password.text,
      );
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
  bool active = true;
  String status = 'draft';
  @override
  void initState() {
    super.initState();
    final r = widget.row ?? {};
    for (final k in [
      'name',
      'handle',
      'title',
      'description',
      'youtube_url',
      'position',
    ]) {
      fields[k] = TextEditingController(
        text: '${r[k] ?? (k == 'position' ? 0 : '')}',
      );
    }
    channel = r['channel_id'];
    section = r['section_id'];
    video = r['video_id'];
    active = r['active'] ?? true;
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
                if (t == 'channels')
                  field('handle', 'YouTube handle, e.g. @ashiy_ish'),
                if (t == 'sections' || t == 'videos')
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
                if (t == 'videos' || t == 'quizzes') field('title', 'Title'),
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
                if (t == 'videos' || t == 'quizzes') ...[
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
                    ? ['name', 'handle']
                    : t == 'sections'
                    ? ['name']
                    : t == 'videos'
                    ? ['title', 'youtube_url', 'description']
                    : ['title'])) {
              r[k] = fields[k]!.text.trim();
            }
            if (t == 'channels' || t == 'sections') {
              r['position'] = int.parse(fields['position']!.text);
              r['active'] = active;
            }
            if (t == 'sections' || t == 'videos') r['channel_id'] = channel;
            if (t == 'videos') r['section_id'] = section;
            if (t == 'quizzes') r['video_id'] = video;
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
      height: 540,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            editable
                ? 'Add 2–6 options per question. The selected answer stays private to owners.'
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
                            labelText: 'Correct answer',
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
                                onPressed: saving || choices.length >= 6
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
                                          q['correct_index'] = 0;
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
                        'options': ['', ''],
                        'correct_index': 0,
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
