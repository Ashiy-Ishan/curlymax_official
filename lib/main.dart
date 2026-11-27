import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'config.dart';
import 'brand.dart';
import 'app_theme.dart';
import 'user_guide.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';
import 'store.dart';
import 'quiz_screen.dart';
import 'notifications.dart';
import 'notification_inbox.dart';
import 'privacy_screen.dart';

const accent = Color(0xFF99C1DE);
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
  late final appearance = AppAppearance(widget.store.prefs);
  bool ready = false, routing = false;
  bool enteredAsGuest = false;
  bool guideSeen = false;
  Store get store => widget.store;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.configError == null) {
      store.onPrivateSessionEnded = () =>
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() => enteredAsGuest = false);
              nav.currentState?.popUntil((route) => route.isFirst);
            }
          });
      store.onAuthenticated = () =>
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
            consumePending();
          });
      unawaited(start());
    }
  }

  Future<void> start() async {
    guideSeen = store.prefs.getBool('viewer_guide_seen') ?? false;
    await store.init();
    ready = true;
    await notifications.init((d) async {
      await store.remember(d);
      if (ready) await consumePending(allowGuest: true);
    });
    await consumePending(allowGuest: true);
    if (mounted) setState(() {});
  }

  Future<void> finishGuide() async {
    await store.prefs.setBool('viewer_guide_seen', true);
    if (!mounted) return;
    setState(() => guideSeen = true);
    if (!store.prefs.containsKey('notification_offer_seen') &&
        notifications.available) {
      WidgetsBinding.instance.addPostFrameCallback((_) => offerNotifications());
    }
  }

  Future<void> offerNotifications() async {
    if (!mounted || !notifications.available) return;
    await store.prefs.setBool('notification_offer_seen', true);
    final chosen = await showDialog<bool>(
      context: nav.currentContext ?? context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Get new video and quiz alerts?'),
        content: const Text(
          'Allow CURLYmax to notify you when new videos or quizzes are published. Change this any time in Settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Allow alerts'),
          ),
        ],
      ),
    );
    if (chosen == true && mounted) {
      try {
        final enabled = await notifications.enable(true);
        if (!enabled && mounted) {
          notice(
            nav.currentContext ?? context,
            'Notification permission was not granted. You can enable it in Settings.',
          );
        }
      } catch (_) {
        if (mounted) {
          notice(
            nav.currentContext ?? context,
            'Could not start alerts. Check your connection and retry in Settings.',
          );
        }
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && ready) {
      unawaited(store.refresh());
      unawaited(consumePending());
      unawaited(notifications.syncPermission().catchError((_) {}));
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
      if (store.signedIn && d['event_id'] is String) {
        unawaited(store.markNotificationRead(d['event_id']).catchError((_) {}));
      }
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
    appearance.dispose();
    store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppearanceScope(
    appearance: appearance,
    child: ValueListenableBuilder<ThemeMode>(
      valueListenable: appearance,
      builder: (context, mode, _) => MaterialApp(
        title: 'CURLYmax',
        navigatorKey: nav,
        debugShowCheckedModeBanner: false,
        theme: curlyTheme(Brightness.light),
        darkTheme: curlyTheme(Brightness.dark),
        themeMode: mode,
        home: widget.configError != null
            ? ConfigurationScreen(details: widget.configError!)
            : !store.signedIn && !enteredAsGuest
            ? WelcomeScreen(
                onGuest: () => setState(() => enteredAsGuest = true),
                onSignIn: () => nav.currentState?.push(
                  MaterialPageRoute(
                    builder: (_) => AuthScreen(
                      store: store,
                      onGuest: () {
                        setState(() => enteredAsGuest = true);
                        nav.currentState?.pop();
                      },
                    ),
                  ),
                ),
              )
            : !guideSeen
            ? UserGuide(onDone: finishGuide)
            : Home(
                store: store,
                notifications: notifications,
                onNotificationOpen: (destination) async {
                  await store.remember(destination);
                  await consumePending(allowGuest: true);
                },
              ),
      ),
    ),
  );
}

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({
    super.key,
    required this.onGuest,
    required this.onSignIn,
  });
  final VoidCallback onGuest, onSignIn;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: CurlymaxMark(size: 104)),
                const SizedBox(height: 28),
                Text(
                  'Watch. Learn. Keep going.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  'Explore CURLYmax videos for free. Sign in to save private notes across devices and take video quizzes.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: onSignIn,
                  icon: const Icon(Icons.login),
                  label: const Text('Sign in or create account'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: onGuest,
                  child: const Text('Continue as guest'),
                ),
                const SizedBox(height: 12),
                Text(
                  'Guests can watch published videos. Notes and quizzes need an account.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
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

Widget label(String text) => Builder(
  builder: (context) => Text(
    text,
    style: TextStyle(
      color: Theme.of(context).colorScheme.primary,
      fontSize: 12,
      fontWeight: FontWeight.w800,
      letterSpacing: 2,
    ),
  ),
);

String? channelLogoUrl(RecordData? channel) {
  for (final field in ['avatar_url', 'youtube_avatar_url']) {
    final value = channel?[field];
    if (value is! String || value.trim().isEmpty) continue;
    final uri = Uri.tryParse(value.trim());
    if (uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty) {
      return uri.toString();
    }
  }
  return null;
}

class ChannelAvatar extends StatelessWidget {
  const ChannelAvatar({super.key, required this.channel, this.radius = 18});
  final RecordData? channel;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final name = '${channel?['name'] ?? 'CURLYmax'}'.trim();
    final words = name.split(RegExp(r'\s+')).where((word) => word.isNotEmpty);
    final initials = words
        .take(2)
        .map((word) => word.characters.first)
        .join()
        .toUpperCase();
    final url = channelLogoUrl(channel);
    final fallback = Center(
      child: Text(
        initials.isEmpty ? 'C' : initials,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontSize: radius * .7,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    return ExcludeSemantics(
      child: ClipOval(
        child: SizedBox.square(
          dimension: radius * 2,
          child: ColoredBox(
            color: const Color(0xFF26331E),
            child: url is String && Uri.tryParse(url)?.scheme == 'https'
                ? Image.network(
                    url,
                    fit: BoxFit.cover,
                    errorBuilder: (_, e, st) => fallback,
                  )
                : fallback,
          ),
        ),
      ),
    );
  }
}

class Home extends StatefulWidget {
  const Home({
    super.key,
    required this.store,
    required this.notifications,
    this.onNotificationOpen,
  });
  final Store store;
  final Notifications notifications;
  final void Function(RecordData)? onNotificationOpen;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  String? channel, section, playlist;
  bool browsingPlaylists = false;
  PlaylistOrder playlistOrder = PlaylistOrder.youtube;
  Store get store => widget.store;
  String get _channelPreference => 'selected_channel:${store.backendUrl}';
  List<RecordData> get activeChannels =>
      store.channels.where((c) => c['active'] != false).toList();
  @override
  void initState() {
    super.initState();
    channel = store.prefs.getString(_channelPreference);
  }

  Future<void> chooseChannel() async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: AnimatedBuilder(
          animation: store,
          builder: (context, _) {
            final channels = activeChannels;
            final selected = channels.any((c) => c['id'] == channel)
                ? channel
                : channels.firstOrNull?['id'];
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .75,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 8, 24, 16),
                    child: Text(
                      'Choose a channel',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (channels.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Channels will appear here when they are published.',
                      ),
                    ),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: channels.length,
                      itemBuilder: (context, index) {
                        final item = channels[index];
                        return ListTile(
                          leading: ChannelAvatar(channel: item, radius: 24),
                          title: Text(item['name'] ?? 'Channel'),
                          subtitle: Text(item['handle'] ?? ''),
                          selected: item['id'] == selected,
                          trailing: item['id'] == selected
                              ? Icon(
                                  Icons.check_circle,
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              : null,
                          onTap: () =>
                              Navigator.pop(sheetContext, item['id'] as String),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    if (!mounted ||
        chosen == null ||
        !activeChannels.any((c) => c['id'] == chosen)) {
      return;
    }
    setState(() {
      channel = chosen;
      section = null;
      playlist = null;
    });
    await store.prefs.setString(_channelPreference, chosen);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) {
      final selectedChannel = activeChannels.any((c) => c['id'] == channel)
          ? channel
          : activeChannels.firstOrNull?['id'];
      final sections = store.sections
          .where((s) => s['channel_id'] == selectedChannel)
          .toList();
      final selectedSection = sections.any((s) => s['id'] == section)
          ? section
          : null;
      final channelPlaylists = store.playlists
          .where((p) => p['channel_id'] == selectedChannel)
          .toList();
      final selectedPlaylist = channelPlaylists.any((p) => p['id'] == playlist)
          ? playlist
          : channelPlaylists.firstOrNull?['id'];
      final channelVideos = store.channelUploads(selectedChannel);
      final popular = store.popularUploads(selectedChannel).take(3).toList();
      final videos = browsingPlaylists && selectedPlaylist == null
          ? <RecordData>[]
          : store.channelUploads(
              selectedChannel,
              playlistId: browsingPlaylists ? selectedPlaylist : null,
              sectionId: browsingPlaylists ? null : selectedSection,
            );
      if (browsingPlaylists && selectedPlaylist != null) {
        sortPlaylistVideos(
          videos,
          store.playlistVideos,
          selectedPlaylist,
          playlistOrder,
        );
      }
      return Scaffold(
        appBar: AppBar(
          title: Text.rich(
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
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'Search learning content',
              icon: const Icon(Icons.search),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SearchScreen(
                    store: store,
                    selectedChannel: selectedChannel,
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Notifications',
              icon: const Icon(Icons.notifications_outlined),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => NotificationInbox(
                    store: store,
                    onOpen: (destination) {
                      (widget.onNotificationOpen ?? widget.notifications.open)
                          ?.call(destination);
                    },
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Choose channel',
              onPressed: chooseChannel,
              icon: ChannelAvatar(
                channel: activeChannels
                    .where((c) => c['id'] == selectedChannel)
                    .firstOrNull,
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
                        'Your next idea starts here.',
                        style: TextStyle(
                          fontSize: 26,
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
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 24),
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
                      const SizedBox(height: 16),
                      if (browsingPlaylists) const SizedBox(height: 12),
                      if (!browsingPlaylists && channelVideos.isNotEmpty) ...[
                        label('LATEST UPLOAD'),
                        const SizedBox(height: 12),
                        VideoCard(
                          video: channelVideos.first,
                          featured: true,
                          onTap: () => open(channelVideos.first),
                        ),
                        const SizedBox(height: 28),
                      ],
                      if (!browsingPlaylists) ...[
                        const Text(
                          'Trending',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Popular on this channel · ranked by total YouTube views',
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (popular.isEmpty)
                          Text(
                            'View counts are not available yet.',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ...popular.map(
                          (video) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: CompactVideoCard(
                              video: video,
                              onTap: () => open(video),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],
                      Text(
                        browsingPlaylists ? 'Your playlists' : 'Latest videos',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (browsingPlaylists)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            LayoutBuilder(
                              builder: (context, constraints) => Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: channelPlaylists.map((p) {
                                  final members = store.channelUploads(
                                    selectedChannel,
                                    playlistId: p['id'],
                                  );
                                  final cover = p['thumbnail_url'] as String?;
                                  return SizedBox(
                                    width: constraints.maxWidth >= 320
                                        ? (constraints.maxWidth - 12) / 2
                                        : constraints.maxWidth,
                                    child: Semantics(
                                      selected: p['id'] == selectedPlaylist,
                                      button: true,
                                      child: Card(
                                        margin: EdgeInsets.zero,
                                        clipBehavior: Clip.antiAlias,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                          side: BorderSide(
                                            color: p['id'] == selectedPlaylist
                                                ? Theme.of(
                                                    context,
                                                  ).colorScheme.primary
                                                : Theme.of(
                                                    context,
                                                  ).colorScheme.outlineVariant,
                                            width: 2,
                                          ),
                                        ),
                                        child: InkWell(
                                          onTap: () => setState(
                                            () => playlist = p['id'],
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              AspectRatio(
                                                aspectRatio: 16 / 9,
                                                child:
                                                    cover != null &&
                                                        cover.startsWith(
                                                          'https://',
                                                        )
                                                    ? Image.network(
                                                        cover,
                                                        fit: BoxFit.cover,
                                                        excludeFromSemantics:
                                                            true,
                                                        errorBuilder:
                                                            (
                                                              _,
                                                              e,
                                                              st,
                                                            ) => const ColoredBox(
                                                              color: Color(
                                                                0xFF26331E,
                                                              ),
                                                              child: Icon(
                                                                Icons
                                                                    .playlist_play,
                                                                color: accent,
                                                                size: 40,
                                                              ),
                                                            ),
                                                      )
                                                    : const ColoredBox(
                                                        color: Color(
                                                          0xFF26331E,
                                                        ),
                                                        child: Icon(
                                                          Icons.playlist_play,
                                                          color: accent,
                                                          size: 40,
                                                        ),
                                                      ),
                                              ),
                                              Padding(
                                                padding: const EdgeInsets.all(
                                                  12,
                                                ),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      p['title'] ?? 'Playlist',
                                                      style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 6),
                                                    Text(
                                                      '${members.length} videos',
                                                      style: TextStyle(
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .onSurfaceVariant,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                            if (selectedPlaylist != null) ...[
                              const SizedBox(height: 24),
                              Text(
                                channelPlaylists.firstWhere(
                                      (p) => p['id'] == selectedPlaylist,
                                    )['title'] ??
                                    'Playlist',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              DropdownButton<PlaylistOrder>(
                                isExpanded: true,
                                value: playlistOrder,
                                onChanged: (value) {
                                  if (value != null) {
                                    setState(() => playlistOrder = value);
                                  }
                                },
                                items: const [
                                  DropdownMenuItem(
                                    value: PlaylistOrder.youtube,
                                    child: Text('YouTube playlist order'),
                                  ),
                                  DropdownMenuItem(
                                    value: PlaylistOrder.newest,
                                    child: Text('Newest first'),
                                  ),
                                  DropdownMenuItem(
                                    value: PlaylistOrder.oldest,
                                    child: Text('Oldest first'),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        )
                      else
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              ChoiceChip(
                                label: const Text('All videos'),
                                selected: selectedSection == null,
                                onSelected: (_) =>
                                    setState(() => section = null),
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
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: Icons.video_library_outlined,
                    title: browsingPlaylists
                        ? (channelPlaylists.isEmpty
                              ? 'No playlists yet'
                              : 'This playlist is waiting for videos')
                        : 'Something good is on the way',
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
                    child: CompactVideoCard(
                      video: videos[i],
                      onTap: () => open(videos[i]),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(24, 0, 24, 28),
                  child: Text(
                    'Made for curious minds.  /  CURLYmax',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: browsingPlaylists ? 1 : 0,
          onDestinationSelected: (index) {
            if (index < 2) {
              setState(() => browsingPlaylists = index == 1);
            } else if (index == 2) {
              if (!store.signedIn) {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => AuthScreen(store: store)),
                );
              } else {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AllNotesScreen(store: store),
                  ),
                );
              }
            } else {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AccountScreen(
                    store: store,
                    notifications: widget.notifications,
                  ),
                ),
              );
            }
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.playlist_play_outlined),
              selectedIcon: Icon(Icons.playlist_play),
              label: 'Learn',
            ),
            NavigationDestination(
              icon: Icon(Icons.edit_note_outlined),
              selectedIcon: Icon(Icons.edit_note),
              label: 'Notes',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
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

enum PlaylistOrder { youtube, newest, oldest }

void sortPlaylistVideos(
  List<RecordData> videos,
  List<RecordData> memberships,
  String playlistId,
  PlaylistOrder order,
) {
  if (order == PlaylistOrder.youtube) {
    final positions = <String, int>{
      for (final item in memberships.where(
        (row) => row['playlist_id'] == playlistId,
      ))
        '${item['video_id']}': (item['position'] as num?)?.toInt() ?? 1 << 30,
    };
    videos.sort(
      (a, b) => (positions['${a['id']}'] ?? 1 << 30).compareTo(
        positions['${b['id']}'] ?? 1 << 30,
      ),
    );
  } else {
    videos.sort(
      (a, b) => order == PlaylistOrder.newest
          ? Store.uploadTime(b).compareTo(Store.uploadTime(a))
          : Store.uploadTime(a).compareTo(Store.uploadTime(b)),
    );
  }
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.store,
    required this.selectedChannel,
  });
  final Store store;
  final String? selectedChannel;
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final query = TextEditingController();
  bool allChannels = false;
  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final text = query.text.trim().toLowerCase();
      final channelId = allChannels ? null : widget.selectedChannel;
      bool matches(String? value) =>
          value?.toLowerCase().contains(text) ?? false;
      final videos = widget.store.videos
          .where(
            (v) =>
                (channelId == null || v['channel_id'] == channelId) &&
                (matches(v['title']) || matches(v['description'])),
          )
          .toList();
      final playlists = widget.store.playlists
          .where(
            (p) =>
                (channelId == null || p['channel_id'] == channelId) &&
                matches(p['title']),
          )
          .toList();
      final quizzes = widget.store.quizzes
          .where(
            (q) =>
                matches(q['title']) &&
                widget.store.videos.any(
                  (v) =>
                      v['id'] == q['video_id'] &&
                      (channelId == null || v['channel_id'] == channelId),
                ),
          )
          .toList();
      return Scaffold(
        appBar: AppBar(title: const Text('Find something to learn')),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    TextField(
                      controller: query,
                      autofocus: true,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Search videos, playlists and quizzes',
                        labelText: 'Search learning content',
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('All channels'),
                      value: allChannels,
                      onChanged: (value) => setState(() => allChannels = value),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: text.isEmpty
                    ? const EmptyState(
                        icon: Icons.search,
                        title: 'What do you want to learn?',
                        message: 'Search by video, playlist or quiz title.',
                      )
                    : videos.isEmpty && playlists.isEmpty && quizzes.isEmpty
                    ? const EmptyState(
                        icon: Icons.search_off,
                        title: 'No matches yet',
                        message: 'Try another word or search all channels.',
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        children: [
                          if (videos.isNotEmpty) ...[
                            Text(
                              'Videos',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            ...videos.map(
                              (v) => CompactVideoCard(
                                video: v,
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => VideoScreen(
                                      store: widget.store,
                                      video: v,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                          if (playlists.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text(
                              'Playlists',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            ...playlists.map(
                              (p) => ListTile(
                                leading: const Icon(Icons.playlist_play),
                                title: Text('${p['title']}'),
                                subtitle: Text(
                                  '${widget.store.playlistVideos.where((pv) => pv['playlist_id'] == p['id']).length} videos',
                                ),
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => SearchPlaylistScreen(
                                      store: widget.store,
                                      playlist: p,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                          if (quizzes.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text(
                              'Quizzes',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            ...quizzes.map(
                              (q) => ListTile(
                                leading: const Icon(Icons.quiz_outlined),
                                title: Text('${q['title']}'),
                                onTap: () {
                                  final video = widget.store.videos
                                      .where((v) => v['id'] == q['video_id'])
                                      .firstOrNull;
                                  if (video != null) {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => VideoScreen(
                                          store: widget.store,
                                          video: video,
                                          initialTab: 2,
                                          openQuiz: q,
                                        ),
                                      ),
                                    );
                                  }
                                },
                              ),
                            ),
                          ],
                        ],
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class SearchPlaylistScreen extends StatelessWidget {
  const SearchPlaylistScreen({
    super.key,
    required this.store,
    required this.playlist,
  });
  final Store store;
  final RecordData playlist;
  @override
  Widget build(BuildContext context) {
    final videos = store.channelUploads(
      playlist['channel_id'],
      playlistId: playlist['id'],
    );
    sortPlaylistVideos(
      videos,
      store.playlistVideos,
      playlist['id'],
      PlaylistOrder.youtube,
    );
    return Scaffold(
      appBar: AppBar(title: Text('${playlist['title']}')),
      body: videos.isEmpty
          ? const EmptyState(
              icon: Icons.playlist_play,
              title: 'This playlist is waiting for videos',
              message: 'Published videos appear here when available.',
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: videos.length,
              itemBuilder: (context, index) => CompactVideoCard(
                video: videos[index],
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        VideoScreen(store: store, video: videos[index]),
                  ),
                ),
              ),
            ),
    );
  }
}

/// Compact, keyboard-accessible rows with no fixed text height.
class CompactVideoCard extends StatelessWidget {
  const CompactVideoCard({super.key, required this.video, required this.onTap});
  final RecordData video;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final views = video['view_count'];
    final uploaded = Store.uploadTime(video);
    final date = uploaded.year > 1970
        ? '${uploaded.year}-${uploaded.month.toString().padLeft(2, '0')}-${uploaded.day.toString().padLeft(2, '0')}'
        : null;
    final metadata = [if (views is num) '$views views', ?date].join(' · ');
    return Semantics(
      button: true,
      label: 'Play ${video['title']}. $metadata',
      onTap: onTap,
      excludeSemantics: true,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 100,
                    height: 64,
                    child: Image.network(
                      'https://i.ytimg.com/vi/${video['youtube_id']}/mqdefault.jpg',
                      fit: BoxFit.cover,
                      excludeFromSemantics: true,
                      errorBuilder: (_, e, st) => const ColoredBox(
                        color: Color(0xFF26331E),
                        child: Icon(Icons.play_arrow_rounded, color: accent),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        video['title'] ?? 'Video',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      if (metadata.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          metadata,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 10,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.north_east_rounded,
                  color: Theme.of(context).colorScheme.primary,
                  size: 20,
                ),
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
          Icon(icon, color: Theme.of(context).colorScheme.primary, size: 40),
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
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
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
                  icon: Icon(
                    Icons.open_in_new,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            child: Text(
              'Player unavailable or embedding restricted? Use “Open in YouTube” above.',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
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
                      style: TextStyle(
                        height: 1.6,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                    Text(
                      'Keep the ideas that stick. Make a private note or test what you learned with a linked quiz.',
                      style: TextStyle(
                        height: 1.5,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                AnimatedBuilder(
                  animation: widget.store,
                  builder: (_, _) => widget.store.signedIn
                      ? NotesPanel(
                          key: ValueKey(widget.store.db.auth.currentUser?.id),
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
                              leading: Icon(
                                Icons.quiz_outlined,
                                color: Theme.of(context).colorScheme.primary,
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
          Icon(
            Icons.lock_outline_rounded,
            size: 40,
            color: Theme.of(context).colorScheme.primary,
          ),
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
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
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
  const AuthScreen({super.key, required this.store, this.onGuest});
  final Store store;
  final VoidCallback? onGuest;
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
    } catch (error) {
      if (mounted) {
        setState(
          () => message = error is StateError
              ? error.message.toString()
              : 'Sign-in failed. Check your details, provider setup, and connection.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Sign in to CURLYmax')),
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
              Text(
                'Your video, quiz, or note will be waiting right here after sign-in.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
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
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: widget.onGuest ?? () => Navigator.pop(context),
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
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            NoteEditor(store: widget.store, video: widget.video, note: note),
      ),
    );
    if (mounted) reload();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (saving) const LinearProgressIndicator(),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Private · Only you',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
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
              label: const Text('New note'),
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

String newNoteId() {
  final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class NoteEditor extends StatefulWidget {
  const NoteEditor({
    super.key,
    required this.store,
    required this.video,
    this.note,
  });
  final Store store;
  final String video;
  final RecordData? note;
  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  late final controller = TextEditingController(
    text: '${widget.note?['body'] ?? ''}',
  );
  late final noteId = widget.note?['id'] as String? ?? newNoteId();
  late bool creating = widget.note == null;
  Timer? timer;
  Future<void>? activeSave;
  bool dirty = false;
  bool allowPop = false;
  bool closing = false;
  String status = 'Private · Only you';

  @override
  void dispose() {
    timer?.cancel();
    controller.dispose();
    super.dispose();
  }

  void changed() {
    dirty = true;
    setState(() => status = 'Unsaved changes');
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 800), () => save());
  }

  Future<void> save() async {
    timer?.cancel();
    if (activeSave != null) await activeSave;
    if (!dirty || controller.text.trim().isEmpty) return;
    final body = controller.text;
    final task = () async {
      setState(() => status = 'Saving…');
      try {
        await widget.store.saveNote(
          widget.video,
          body,
          id: noteId,
          create: creating,
        );
        creating = false;
        dirty = controller.text != body;
        if (mounted) {
          setState(
            () => status = dirty ? 'Unsaved changes' : 'Saved to your account',
          );
        }
      } catch (_) {
        dirty = true;
        if (mounted) {
          setState(
            () => status = 'Could not save · Check your connection and retry',
          );
        }
      }
    }();
    activeSave = task;
    await task;
    activeSave = null;
    if (dirty && status == 'Unsaved changes' && mounted) {
      timer = Timer(const Duration(milliseconds: 800), () => save());
    }
  }

  Future<void> close() async {
    if (closing) return;
    closing = true;
    await save();
    if (!mounted) return;
    if (dirty && controller.text.trim().isNotEmpty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('This note is not saved'),
          content: const Text('Retry saving or discard these changes?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Keep editing'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Discard changes'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) {
        closing = false;
        return;
      }
    }
    setState(() => allowPop = true);
    Navigator.pop(context);
  }

  void checklist() {
    final selection = controller.selection;
    final offset = selection.isValid
        ? selection.baseOffset
        : controller.text.length;
    final prefix =
        offset <= 0 || controller.text.substring(0, offset).endsWith('\n')
        ? '☐ '
        : '\n☐ ';
    controller.value = TextEditingValue(
      text: controller.text.replaceRange(offset, offset, prefix),
      selection: TextSelection.collapsed(offset: offset + prefix.length),
    );
    changed();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: allowPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) close();
    },
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Done editing',
          icon: const Icon(Icons.arrow_back),
          onPressed: close,
        ),
        title: Text(widget.note == null ? 'New note' : 'Your note'),
        actions: [
          IconButton(
            tooltip: 'Save now',
            icon: const Icon(Icons.cloud_done_outlined),
            onPressed: save,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                children: [
                  const Icon(Icons.lock_outline, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        status,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: checklist,
                    icon: const Icon(Icons.checklist),
                    label: const Text('Checklist'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: TextField(
                  controller: controller,
                  autofocus: true,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  maxLength: 20000,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  onChanged: (_) => changed(),
                  decoration: const InputDecoration(
                    labelText: 'Your private note',
                    hintText: 'What stood out to you?',
                    alignLabelWithHint: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class AllNotesScreen extends StatefulWidget {
  const AllNotesScreen({super.key, required this.store});
  final Store store;
  @override
  State<AllNotesScreen> createState() => _AllNotesScreenState();
}

class _AllNotesScreenState extends State<AllNotesScreen> {
  late Future<List<RecordData>> rows = widget.store.allNotes();
  void reload() => setState(() => rows = widget.store.allNotes());
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('My notes'),
      actions: [
        IconButton(
          tooltip: 'Refresh notes',
          onPressed: reload,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: FutureBuilder<List<RecordData>>(
      future: rows,
      builder: (context, snapshot) {
        if (!snapshot.hasData && !snapshot.hasError) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) return ErrorPanel(onRetry: reload);
        final notes = snapshot.data!;
        if (notes.isEmpty) {
          return const EmptyState(
            icon: Icons.edit_note_outlined,
            title: 'No notes yet',
            message: 'Open a video and capture something you want to remember.',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: notes.length,
          itemBuilder: (context, index) {
            final note = notes[index];
            final video = widget.store.videos
                .where((v) => v['id'] == note['video_id'])
                .firstOrNull;
            return Card(
              child: ListTile(
                title: Text(video?['title'] ?? 'Video note'),
                subtitle: Text(
                  '${note['body']}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: video == null
                    ? null
                    : () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => VideoScreen(
                              store: widget.store,
                              video: video,
                              initialTab: 1,
                            ),
                          ),
                        );
                        reload();
                      },
              ),
            );
          },
        );
      },
    ),
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

  Future<void> logOut() async {
    setState(() => busy = true);
    await attempt(context, () async {
      await widget.notifications.enable(false).catchError((_) => false);
      await widget.store.signOut();
    });
    if (mounted) setState(() => busy = false);
  }

  Future<void> confirmDeleteAccount() async {
    var confirmation = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) => AlertDialog(
          title: const Text('Delete your account and data?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Account: ${widget.store.userLabel}'),
                const SizedBox(height: 12),
                const Text(
                  'This permanently deletes your sign-in account, private notes, quiz history and in-progress quizzes across devices. It cannot be undone. Public videos and quizzes remain.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'If this is your publishing account, owner access is also removed. You would need the Supabase console to appoint a new owner.',
                ),
                const SizedBox(height: 16),
                const Text(
                  'Sign in again first if your last sign-in was more than 15 minutes ago.',
                ),
                const SizedBox(height: 12),
                TextField(
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Type DELETE to confirm',
                  ),
                  onChanged: (value) =>
                      updateDialog(() => confirmation = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: confirmation == 'DELETE'
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: const Text('Delete my account'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    await attempt(context, () async {
      await widget.store.deleteAccount();
      await widget.notifications.enable(false).catchError((_) => false);
      if (!mounted) return;
      notice(context, 'Your account and private data were deleted.');
      Navigator.of(context).popUntil((route) => route.isFirst);
    });
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.store, widget.notifications]),
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          label('A PLACE FOR YOUR CURIOSITY'),
          const AppearancePicker(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.menu_book_outlined),
            title: const Text('User guide'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (guideContext) =>
                    UserGuide(onDone: () => Navigator.pop(guideContext)),
              ),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy policy'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PrivacyScreen()),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.manage_accounts_outlined),
            title: const Text('Request account deletion by email'),
            subtitle: const Text(AppConfig.supportEmail),
            onTap: () => composeSupportEmail(context, deletion: true),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.support_agent),
            title: const Text('Email support'),
            subtitle: const Text(AppConfig.supportEmail),
            onTap: () => composeSupportEmail(context),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.play_circle_outline, size: 40),
                    title: Text('Who am I'),
                  ),
                  Text(
                    'CURLYmax · @ashiy_ish',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Created by Ashinshana Ishan. CURLYmax brings together '
                    'videos from @ashiy_ish, video quizzes and private notes '
                    'so you can watch, learn and keep your ideas in one place.',
                  ),
                  const SizedBox(height: 24),
                  const Divider(),
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.account_circle_outlined),
                    title: Text('Your account'),
                  ),
                  Text(
                    widget.store.signedIn
                        ? widget.store.userLabel
                        : 'Guest viewer',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.store.signedIn
                        ? 'Your private notes and quiz history belong to this account.'
                        : 'You can watch videos without signing in.',
                  ),
                  if (widget.store.signedIn) ...[
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: busy ? null : logOut,
                          icon: const Icon(Icons.logout),
                          label: const Text('Log out'),
                        ),
                        TextButton.icon(
                          onPressed: busy ? null : confirmDeleteAccount,
                          icon: const Icon(Icons.delete_forever_outlined),
                          label: const Text('Clear all my data'),
                          style: TextButton.styleFrom(
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.error,
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (busy) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(
                      semanticsLabel: 'Updating your account',
                    ),
                  ],
                ],
              ),
            ),
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
                  return Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text(
                      'No scores yet. Find a quiz on a video to get started.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                return Column(
                  children: snapshot.data!
                      .map(
                        (a) => Card(
                          child: ListTile(
                            leading: Icon(
                              Icons.check_circle_outline,
                              color: Theme.of(context).colorScheme.primary,
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
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
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
          ],
          const SizedBox(height: 32),
          Text(
            'CURLYmax 1.3\nVideos play through YouTube. Notes are private to your account. Quiz submissions are scored securely on the server.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.6,
              fontSize: 12,
            ),
          ),
        ],
      ),
    ),
  );
}
