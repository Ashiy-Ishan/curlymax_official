import 'dart:async';
import 'package:flutter/foundation.dart';
import 'config.dart';
import 'brand.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';
import 'store.dart';
import 'quiz_screen.dart';
import 'notifications.dart';

const accent = Color(0xFFCEFF5E);
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  String? configError = AppConfig.validateSupabase();
  if (configError == null) {
    try {
      await Supabase.initialize(
        url: AppConfig.supabaseUrl,
        anonKey: AppConfig.supabaseKey,
      );
    } catch (_) {
      configError =
          'Unable to initialize the account connection. Check the public client configuration.';
    }
  }
  final store = Store(await SharedPreferences.getInstance());
  runApp(CurlyApp(store: store, configError: configError));
}

class CurlyApp extends StatefulWidget {
  const CurlyApp({super.key, required this.store, this.configError});
  final Store store;
  final String? configError;
  @override
  State<CurlyApp> createState() => _CurlyAppState();
}

class _CurlyAppState extends State<CurlyApp> with WidgetsBindingObserver {
  final nav = GlobalKey<NavigatorState>();
  final notifications = Notifications();
  bool ready = false, routing = false;
  Store get store => widget.store;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.configError == null) {
      store.onAuthenticated = () =>
          WidgetsBinding.instance.addPostFrameCallback((_) => consumePending());
      unawaited(start());
    }
  }

  Future<void> start() async {
    await store.init();
    ready = true;
    await notifications.init((d) async {
      await store.remember(d);
      if (ready) await consumePending(allowGuest: true);
    });
    await consumePending(allowGuest: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && ready) {
      unawaited(store.refresh());
      unawaited(consumePending());
    }
  }

  Future<void> consumePending({bool allowGuest = false}) async {
    final d = store.pending;
    if (d == null ||
        routing ||
        nav.currentState == null ||
        (!store.signedIn && !allowGuest)) {
      return;
    }
    routing = true;
    try {
      await store.refresh();
      final kind = d['kind'] ?? 'video';
      RecordData? quiz;
      String? videoId = d['video_id'] as String?;
      if (kind == 'quiz') {
        quiz = store.quizzes.where((q) => q['id'] == d['item_id']).firstOrNull;
        videoId = quiz?['video_id'];
      } else {
        videoId ??= d['item_id'] as String?;
      }
      final video = store.videos.where((v) => v['id'] == videoId).firstOrNull;
      if (video == null) {
        if (store.error != null) {
          notice(
            nav.currentContext!,
            'Destination saved. Reconnect and try again.',
          );
          return;
        }
        await store.clearPending();
        notice(nav.currentContext!, 'This item is no longer published.');
        return;
      }
      if ((kind == 'quiz' || d['tab'] == 1) && !store.signedIn) {
        nav.currentState!.push(
          MaterialPageRoute(builder: (_) => AuthScreen(store: store)),
        );
        return;
      }
      await store.clearPending();
      nav.currentState!.popUntil((r) => r.isFirst);
      nav.currentState!.push(
        MaterialPageRoute(
          builder: (_) => VideoScreen(
            store: store,
            video: video,
            initialTab: d['tab'] as int? ?? (kind == 'quiz' ? 2 : 0),
            openQuiz: quiz,
          ),
        ),
      );
    } finally {
      routing = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    notifications.dispose();
    store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'CURLYmax',
    navigatorKey: nav,
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: Brightness.dark,
        primary: accent,
        surface: const Color(0xFF121611),
      ),
      scaffoldBackgroundColor: const Color(0xFF0B0E0B),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF0B0E0B),
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF191F18),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontWeight: FontWeight.w800,
          letterSpacing: -1.4,
        ),
        headlineMedium: TextStyle(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.7,
        ),
        titleLarge: TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    home: widget.configError != null
        ? ConfigurationScreen(details: widget.configError!)
        : Home(store: store, notifications: notifications),
  );
}

class ConfigurationScreen extends StatelessWidget {
  const ConfigurationScreen({super.key, required this.details});
  final String details;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CurlymaxMark(size: 96),
                const SizedBox(height: 24),
                Text(
                  'CURLYmax',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 16),
                const Text(
                  'This installation is not connected yet.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Install a configured build from the channel owner to browse videos and sign in.',
                  textAlign: TextAlign.center,
                ),
                if (kDebugMode) ...[
                  const SizedBox(height: 24),
                  SelectableText(
                    details,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: accent),
                  ),
                  const SizedBox(height: 12),
                  const SelectableText(
                    'flutter run --dart-define-from-file=config/live.json',
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

void notice(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

Future<void> attempt(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (_) {
    if (context.mounted) {
      notice(
        context,
        'Couldn’t complete that action. Check your connection and try again.',
      );
    }
  }
}

Widget label(String text) => Text(
  text,
  style: const TextStyle(
    color: accent,
    fontSize: 12,
    fontWeight: FontWeight.w800,
    letterSpacing: 2,
  ),
);

class Home extends StatefulWidget {
  const Home({super.key, required this.store, required this.notifications});
  final Store store;
  final Notifications notifications;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  String? channel, section;
  Store get store => widget.store;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) {
      final selectedChannel = store.channels.any((c) => c['id'] == channel)
          ? channel
          : store.channels.firstOrNull?['id'];
      final sections = store.sections
          .where((s) => s['channel_id'] == selectedChannel)
          .toList();
      final selectedSection = sections.any((s) => s['id'] == section)
          ? section
          : null;
      final channelVideos = store.videos
          .where((v) => v['channel_id'] == selectedChannel)
          .toList();
      final videos = channelVideos
          .where(
            (v) =>
                selectedSection == null || v['section_id'] == selectedSection,
          )
          .toList();
      return Scaffold(
        appBar: AppBar(
          title: const Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'CURLY',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1,
                  ),
                ),
                TextSpan(
                  text: 'max',
                  style: TextStyle(color: accent, fontWeight: FontWeight.w400),
                ),
              ],
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'Account and settings',
              icon: const Icon(Icons.person_outline_rounded),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AccountScreen(
                    store: store,
                    notifications: widget.notifications,
                  ),
                ),
              ),
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: store.refresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      label('WATCH. LEARN. MAKE IT YOURS.'),
                      const SizedBox(height: 12),
                      const Text(
                        'Stay curious.\nGo a little further.',
                        style: TextStyle(
                          fontSize: 36,
                          height: 1.12,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.5,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        store.channels
                                .where((c) => c['id'] == selectedChannel)
                                .firstOrNull?['handle'] ??
                            'Your next idea starts here',
                        style: const TextStyle(color: Colors.white60),
                      ),
                      const SizedBox(height: 24),
                      if (store.channels.length > 1)
                        DropdownButtonFormField<String>(
                          initialValue: selectedChannel,
                          decoration: const InputDecoration(
                            labelText: 'Channel',
                          ),
                          items: store.channels
                              .map(
                                (c) => DropdownMenuItem<String>(
                                  value: c['id'],
                                  child: Text(c['name']),
                                ),
                              )
                              .toList(),
                          onChanged: (v) => setState(() {
                            channel = v;
                            section = null;
                          }),
                        ),
                      if (store.loading)
                        const LinearProgressIndicator(minHeight: 2),
                      if (store.error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                store.error!,
                                style: const TextStyle(
                                  color: Colors.orangeAccent,
                                ),
                              ),
                              TextButton.icon(
                                onPressed: store.refresh,
                                icon: const Icon(Icons.refresh),
                                label: const Text('Retry connection'),
                              ),
                            ],
                          ),
                        ),
                      if (channelVideos.isNotEmpty) ...[
                        label('LATEST UPLOAD'),
                        const SizedBox(height: 12),
                        VideoCard(
                          video: channelVideos.first,
                          featured: true,
                          onTap: () => open(channelVideos.first),
                        ),
                        const SizedBox(height: 28),
                      ],
                      const Text(
                        'Find your next spark',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            ChoiceChip(
                              label: const Text('All videos'),
                              selected: selectedSection == null,
                              onSelected: (_) => setState(() => section = null),
                            ),
                            const SizedBox(width: 8),
                            ...sections.map(
                              (s) => Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(s['name']),
                                  selected: s['id'] == selectedSection,
                                  onSelected: (_) =>
                                      setState(() => section = s['id']),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
              if (videos.isEmpty && !store.loading)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: Icons.video_library_outlined,
                    title: 'Something good is on the way',
                    message:
                        'Published videos will appear here. Pull down to refresh.',
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                sliver: SliverList.builder(
                  itemCount: videos.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: VideoCard(
                      video: videos[i],
                      onTap: () => open(videos[i]),
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(24, 0, 24, 28),
                  child: Text(
                    'Made for curious minds.  /  CURLYmax',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  void open(RecordData video) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => VideoScreen(store: store, video: video),
    ),
  );
}

class VideoCard extends StatelessWidget {
  const VideoCard({
    super.key,
    required this.video,
    required this.onTap,
    this.featured = false,
  });
  final RecordData video;
  final VoidCallback onTap;
  final bool featured;
  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.network(
                  'https://i.ytimg.com/vi/${video['youtube_id']}/hqdefault.jpg',
                  fit: BoxFit.cover,
                  errorBuilder: (_, e, s) => Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFF334326), Color(0xFF171E14)],
                      ),
                    ),
                    child: const Icon(
                      Icons.play_circle_outline,
                      size: 56,
                      color: accent,
                    ),
                  ),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.center,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black54],
                    ),
                  ),
                ),
                const Center(
                  child: CircleAvatar(
                    radius: 26,
                    backgroundColor: accent,
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.black,
                      size: 34,
                    ),
                  ),
                ),
                if (featured)
                  Positioned(
                    left: 14,
                    top: 14,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0B0E0B),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'THE LATEST',
                        style: TextStyle(
                          color: accent,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        video['title'],
                        style: TextStyle(
                          fontSize: featured ? 21 : 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'WATCH  ·  NOTES  ·  QUIZ',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 10,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.north_east_rounded, color: accent, size: 20),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final String title, message;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: accent, size: 40),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white60),
          ),
        ],
      ),
    ),
  );
}

class VideoScreen extends StatefulWidget {
  const VideoScreen({
    super.key,
    required this.store,
    required this.video,
    this.initialTab = 0,
    this.openQuiz,
  });
  final Store store;
  final RecordData video;
  final int initialTab;
  final RecordData? openQuiz;
  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  YoutubePlayerController? player;
  bool playing = false;
  @override
  void initState() {
    super.initState();
    if (widget.openQuiz != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => openQuiz(widget.openQuiz!),
      );
    }
  }

  @override
  void dispose() {
    unawaited(player?.close());
    super.dispose();
  }

  Future<void> gate(int tab, {RecordData? quiz}) async {
    unawaited(pause());
    await widget.store.remember({
      'kind': quiz == null ? 'video' : 'quiz',
      'item_id': quiz?['id'] ?? widget.video['id'],
      'video_id': widget.video['id'],
      'tab': tab,
    });
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => AuthScreen(store: widget.store)),
      );
    }
  }

  void openQuiz(RecordData quiz) {
    if (!widget.store.signedIn) {
      unawaited(gate(2, quiz: quiz));
      return;
    }
    unawaited(pause());
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => QuizScreen(store: widget.store, quiz: quiz),
      ),
    );
  }

  Future<void> pause() async {
    try {
      await player?.pauseVideo().timeout(const Duration(seconds: 2));
    } catch (_) {
      /* Navigation remains available if YouTube is unreachable. */
    }
  }

  void loadPlayer() {
    try {
      player = YoutubePlayerController.fromVideoId(
        videoId: widget.video['youtube_id'],
        autoPlay: false,
        params: const YoutubePlayerParams(
          showControls: true,
          showFullscreenButton: true,
          strictRelatedVideos: true,
        ),
      );
      setState(() => playing = true);
    } catch (_) {
      notice(context, 'Player unavailable. Use Open in YouTube.');
    }
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    initialIndex: widget.initialTab,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Your next spark', style: TextStyle(fontSize: 17)),
      ),
      body: Column(
        children: [
          // Player is created on deliberate user interaction, so scrolling/browsing never starts audio.
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .34,
            ),
            child: playing
                ? YoutubePlayer(controller: player!, aspectRatio: 16 / 9)
                : AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Material(
                      color: const Color(0xFF1E2918),
                      child: InkWell(
                        onTap: loadPlayer,
                        child: const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.play_circle_fill_rounded,
                                size: 64,
                                color: accent,
                              ),
                              SizedBox(height: 8),
                              Text('Load YouTube player'),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.video['title'],
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 19,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Open in YouTube',
                  onPressed: () => attempt(context, () async {
                    await pause();
                    if (!await launchUrl(
                      Uri.parse(
                        'https://www.youtube.com/watch?v=${widget.video['youtube_id']}',
                      ),
                      mode: LaunchMode.externalApplication,
                    )) {
                      throw StateError('No app');
                    }
                  }),
                  icon: const Icon(Icons.open_in_new, color: accent),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            child: Text(
              'Player unavailable or embedding restricted? Use “Open in YouTube” above.',
              style: TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ),
          const TabBar(
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'My notes'),
              Tab(text: 'Quiz'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    label('ABOUT THIS VIDEO'),
                    const SizedBox(height: 14),
                    Text(
                      widget.video['description'],
                      style: const TextStyle(
                        height: 1.6,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'A little more than watching.',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Keep the ideas that stick. Make a private note or test what you learned with a linked quiz.',
                      style: TextStyle(height: 1.5, color: Colors.white60),
                    ),
                  ],
                ),
                AnimatedBuilder(
                  animation: widget.store,
                  builder: (_, _) => widget.store.signedIn
                      ? NotesPanel(
                          store: widget.store,
                          video: widget.video['id'],
                        )
                      : SignInPrompt(
                          message: 'Keep your ideas close',
                          detail:
                              'Sign in to save private notes for this video and sync them across devices.',
                          onTap: () => gate(1),
                        ),
                ),
                AnimatedBuilder(
                  animation: widget.store,
                  builder: (_, _) {
                    final quizzes = widget.store.quizzes
                        .where((q) => q['video_id'] == widget.video['id'])
                        .toList();
                    if (quizzes.isEmpty) {
                      return const EmptyState(
                        icon: Icons.quiz_outlined,
                        title: 'No quiz just yet',
                        message: 'Check back after the next update.',
                      );
                    }
                    return ListView(
                      padding: const EdgeInsets.all(20),
                      children: [
                        label('PUT YOUR CURIOSITY TO WORK'),
                        const SizedBox(height: 14),
                        ...quizzes.map(
                          (q) => Card(
                            child: ListTile(
                              contentPadding: const EdgeInsets.all(16),
                              leading: const Icon(
                                Icons.quiz_outlined,
                                color: accent,
                              ),
                              title: Text(q['title']),
                              subtitle: const Text(
                                'Check your understanding · Retry anytime',
                              ),
                              trailing: const Icon(Icons.arrow_forward),
                              onTap: () => openQuiz(q),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class SignInPrompt extends StatelessWidget {
  const SignInPrompt({
    super.key,
    required this.message,
    required this.detail,
    required this.onTap,
  });
  final String message, detail;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          const Icon(Icons.lock_outline_rounded, size: 40, color: accent),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white60),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: onTap,
            child: const Text('Sign in to continue'),
          ),
        ],
      ),
    ),
  );
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.store});
  final Store store;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final email = TextEditingController(), password = TextEditingController();
  bool busy = false, create = false;
  String? message;
  bool closing = false;
  @override
  void initState() {
    super.initState();
    widget.store.addListener(authChanged);
  }

  void authChanged() {
    if (!closing &&
        widget.store.signedIn &&
        widget.store.pending == null &&
        mounted &&
        ModalRoute.of(context)?.isCurrent == true) {
      closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.pop(context);
        }
      });
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(authChanged);
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Sign-in failed. Check your details, provider setup, and connection.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Make it yours')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              label('YOUR CURLYmax SPACE'),
              const SizedBox(height: 12),
              Text(
                create ? 'Join the curious.' : 'Welcome back.',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 12),
              const Text(
                'Your video, quiz, or note will be waiting right here after sign-in.',
                style: TextStyle(color: Colors.white60, height: 1.5),
              ),
              const SizedBox(height: 28),

              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () => run(() async {
                        await widget.store.signInWithGoogle();
                      }),
                icon: const Icon(Icons.account_circle_outlined),
                label: const Text('Continue with Google'),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: 'Email address'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                obscureText: true,
                autofillHints: [
                  create ? AutofillHints.newPassword : AutofillHints.password,
                ],
                decoration: const InputDecoration(labelText: 'Password'),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: busy
                    ? null
                    : () => run(() async {
                        if (!email.text.contains('@') ||
                            password.text.length < 8) {
                          setState(
                            () => message =
                                'Enter an email and a password of at least 8 characters.',
                          );
                          return;
                        }
                        if (create) {
                          final hasSession = await widget.store.createAccount(
                            email.text,
                            password.text,
                          );
                          if (!hasSession && mounted) {
                            setState(
                              () => message =
                                  'Check your email to confirm your account, then return to sign in.',
                            );
                          }
                        } else {
                          await widget.store.signInWithEmail(
                            email.text,
                            password.text,
                          );
                        }
                      }),
                child: Text(create ? 'Create account' : 'Sign in with email'),
              ),
              TextButton(
                onPressed: busy ? null : () => setState(() => create = !create),
                child: Text(
                  create
                      ? 'Already have an account? Sign in'
                      : 'New here? Create an account',
                ),
              ),
              if (busy) const LinearProgressIndicator(),
              if (message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    message!,
                    semanticsLabel: message,
                    style: const TextStyle(color: accent),
                  ),
                ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Keep browsing as a guest'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class NotesPanel extends StatefulWidget {
  const NotesPanel({super.key, required this.store, required this.video});
  final Store store;
  final String video;
  @override
  State<NotesPanel> createState() => _NotesPanelState();
}

class _NotesPanelState extends State<NotesPanel> {
  late Future<List<RecordData>> rows;
  bool saving = false;
  final drafts = <String, String>{};
  @override
  void initState() {
    super.initState();
    rows = widget.store.notes(widget.video);
  }

  void reload() => setState(() => rows = widget.store.notes(widget.video));
  Future<void> removeNote(RecordData note) async {
    if (saving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this note?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => saving = true);
    try {
      await widget.store.deleteNote(note['id']);
      if (mounted) reload();
    } catch (_) {
      if (mounted) {
        notice(
          context,
          'Note not deleted. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> edit([RecordData? note]) async {
    if (saving) return;
    final draftKey = note?['id'] as String? ?? '_new';
    final controller = TextEditingController(
      text: drafts[draftKey] ?? note?['body'],
    );
    final body = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(note == null ? 'Capture an idea' : 'Edit your note'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          maxLength: 20000,
          decoration: const InputDecoration(hintText: 'What stood out to you?'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: const Text('Save note'),
          ),
        ],
      ),
    );
    // The dialog owns a route animation; defer disposal until it has finished.
    Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
    if (body != null && mounted) {
      setState(() => saving = true);
      try {
        await widget.store.saveNote(widget.video, body, id: note?['id']);
        drafts.remove(draftKey);
        if (mounted) reload();
      } catch (_) {
        drafts[draftKey] = body;
        if (mounted) {
          notice(
            context,
            'Note not saved. Check your connection, then tap Add or Edit to retry your draft.',
          );
        }
      } finally {
        if (mounted) setState(() => saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (saving) const LinearProgressIndicator(),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Private · Only you',
                style: TextStyle(color: Colors.white54),
              ),
            ),
            IconButton(
              tooltip: 'Refresh notes',
              onPressed: reload,
              icon: const Icon(Icons.refresh),
            ),
            FilledButton.icon(
              onPressed: saving ? null : edit,
              icon: const Icon(Icons.add),
              label: const Text('Add note'),
            ),
          ],
        ),
      ),
      Expanded(
        child: FutureBuilder<List<RecordData>>(
          future: rows,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) return ErrorPanel(onRetry: reload);
            if (snapshot.data!.isEmpty) {
              return const EmptyState(
                icon: Icons.edit_note_rounded,
                title: 'An idea worth keeping?',
                message: 'Add your first note. Revisit it anytime.',
              );
            }
            return RefreshIndicator(
              onRefresh: () async {
                reload();
                await rows;
              },
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: snapshot.data!
                    .map(
                      (n) => Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                n['body'],
                                style: const TextStyle(height: 1.5),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  IconButton(
                                    tooltip: 'Edit note',
                                    onPressed: () => edit(n),
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 20,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Delete note',
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 20,
                                    ),
                                    onPressed: saving
                                        ? null
                                        : () => removeNote(n),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            );
          },
        ),
      ),
    ],
  );
}

class ErrorPanel extends StatelessWidget {
  const ErrorPanel({super.key, required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'Can’t load this right now. Check your connection.',
            textAlign: TextAlign.center,
          ),
        ),
        FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
        ),
      ],
    ),
  );
}

class AccountScreen extends StatefulWidget {
  const AccountScreen({
    super.key,
    required this.store,
    required this.notifications,
  });
  final Store store;
  final Notifications notifications;
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool busy = false;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.store, widget.notifications]),
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Your space')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          label('A PLACE FOR YOUR CURIOSITY'),
          const SizedBox(height: 20),
          Text(
            widget.store.signedIn
                ? widget.store.userLabel
                : 'Hello, curious mind.',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 16),
          if (!widget.store.signedIn)
            FilledButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AuthScreen(store: widget.store),
                ),
              ),
              child: const Text('Sign in'),
            ),
          const SizedBox(height: 24),
          Card(
            child: SwitchListTile(
              title: const Text('New sparks, straight to you'),
              subtitle: Text(widget.notifications.status),
              value:
                  widget.notifications.available &&
                  widget.notifications.enabled,
              onChanged: busy || !widget.notifications.available
                  ? null
                  : (value) async {
                      if (!widget.notifications.available) {
                        notice(
                          context,
                          'Notifications need a configured Firebase Android build.',
                        );
                        return;
                      }
                      setState(() => busy = true);
                      await attempt(context, () async {
                        final enabled = await widget.notifications.enable(
                          value,
                        );
                        if (context.mounted && value && !enabled) {
                          notice(
                            context,
                            'Permission declined. You can allow notifications in Android settings.',
                          );
                        }
                      });
                      if (mounted) setState(() => busy = false);
                    },
            ),
          ),
          if (widget.store.signedIn) ...[
            const SizedBox(height: 28),
            const Text(
              'Your quiz journey',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            FutureBuilder<List<RecordData>>(
              future: widget.store.attempts(),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return ErrorPanel(onRetry: () => setState(() {}));
                }
                if (snapshot.data!.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text(
                      'No scores yet. Find a quiz on a video to get started.',
                      style: TextStyle(color: Colors.white60),
                    ),
                  );
                }
                return Column(
                  children: snapshot.data!
                      .map(
                        (a) => Card(
                          child: ListTile(
                            leading: const Icon(
                              Icons.check_circle_outline,
                              color: accent,
                            ),
                            title: Text(
                              widget.store.quizzes
                                      .where((q) => q['id'] == a['quiz_id'])
                                      .firstOrNull?['title'] ??
                                  'Quiz attempt',
                            ),
                            subtitle: Text(
                              a['submitted_at'].toString().split('T').first,
                            ),
                            trailing: Text(
                              '${a['score']} / ${a['total']}',
                              style: const TextStyle(
                                color: accent,
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                );
              },
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: () => attempt(context, () async {
                await widget.notifications
                    .enable(false)
                    .catchError((_) => false);
                await widget.store.signOut();
                if (mounted) setState(() {});
              }),
              child: const Text('Sign out'),
            ),
          ],
          const SizedBox(height: 32),
          const Text(
            'CURLYmax 1.1\nVideos play through YouTube. Notes are private to your account. Quiz submissions are scored securely on the server.',
            style: TextStyle(color: Colors.white38, height: 1.6, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}
