import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

ThemeData studioTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xff99c1de),
        brightness: brightness,
      ).copyWith(
        primary: dark ? const Color(0xff99c1de) : const Color(0xff285472),
        onPrimary: dark ? const Color(0xff102331) : Colors.white,
        primaryContainer: dark
            ? const Color(0xff284659)
            : const Color(0xffbcd4e6),
        onPrimaryContainer: dark
            ? const Color(0xffd6e2e9)
            : const Color(0xff102331),
        secondaryContainer: dark
            ? const Color(0xff304744)
            : const Color(0xffc5dedd),
        onSecondaryContainer: dark
            ? const Color(0xffdbe7e4)
            : const Color(0xff193c39),
        tertiaryContainer: dark
            ? const Color(0xff533543)
            : const Color(0xfffad2e1),
        onTertiaryContainer: dark
            ? const Color(0xfffde2e4)
            : const Color(0xff512739),
        surface: dark ? const Color(0xff121820) : const Color(0xfffff1e6),
        onSurface: dark ? const Color(0xfff0efeb) : const Color(0xff202b35),
        surfaceContainerLow: dark
            ? const Color(0xff1d2833)
            : const Color(0xfff0efeb),
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
  );
}

class StudioApp extends StatefulWidget {
  const StudioApp({
    super.key,
    required this.home,
    this.showGuideOnStart = true,
  });
  final Widget home;
  final bool showGuideOnStart;
  @override
  State<StudioApp> createState() => _StudioAppState();
}

class _StudioAppState extends State<StudioApp> {
  final navigator = GlobalKey<NavigatorState>();
  ThemeMode mode = ThemeMode.system;
  SharedPreferences? preferences;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      preferences = prefs;
      setState(() {
        mode = ThemeMode.values.firstWhere(
          (m) => m.name == prefs.getString('studio_theme'),
          orElse: () => ThemeMode.system,
        );
      });
      if (widget.showGuideOnStart &&
          prefs.getBool('studio_guide_seen') != true) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final context = navigator.currentContext;
          if (!mounted || context == null) return;
          await showStudioGuide(context);
          await prefs.setBool('studio_guide_seen', true);
        });
      }
    } catch (_) {
      // Local appearance preferences must not block owner authentication.
    }
  }

  Future<void> changeMode(ThemeMode value) async {
    setState(() => mode = value);
    try {
      final prefs = preferences ?? await SharedPreferences.getInstance();
      await prefs.setString('studio_theme', value.name);
    } catch (_) {
      final context = navigator.currentContext;
      if (mounted && context != null && context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text(
              'Theme changed for this session. Could not save the preference.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigator,
    debugShowCheckedModeBanner: false,
    title: 'CURLYmax Studio',
    theme: studioTheme(Brightness.light),
    darkTheme: studioTheme(Brightness.dark),
    themeMode: mode,
    home: widget.home,
  );
}

Future<void> showStudioPreferences(BuildContext context) async {
  final app = context.findAncestorStateOfType<_StudioAppState>();
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Your workspace'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<ThemeMode>(
              initialValue: app?.mode ?? ThemeMode.system,
              decoration: const InputDecoration(labelText: 'Appearance'),
              items: const [
                DropdownMenuItem(
                  value: ThemeMode.system,
                  child: Text('System'),
                ),
                DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
              ],
              onChanged: (value) {
                if (value != null) app?.changeMode(value);
              },
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => showStudioGuide(dialogContext),
              icon: const Icon(Icons.help_outline),
              label: const Text('Open user guide'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

Future<void> showStudioGuide(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('Welcome to your Studio'),
    content: const SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your publishing checklist',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 16),
            Text(
              '1. Sign in with the approved owner account. Viewer accounts cannot publish or manage content.',
            ),
            SizedBox(height: 12),
            Text(
              '2. Add a channel and section. In YouTube, connect the channel and sync its videos and playlists.',
            ),
            SizedBox(height: 12),
            Text(
              '3. In Quizzes, choose a video and add questions or import quiz JSON. Review the draft, then publish when ready.',
            ),
            SizedBox(height: 12),
            Text(
              '4. Check Alerts after publishing. Pending alerts need the configured server sender; refreshing this app does not send them.',
            ),
            SizedBox(height: 12),
            Text(
              'Use the side menu on your phone or the navigation rail on a wider screen. Appearance and this guide are always in Workspace options.',
            ),
          ],
        ),
      ),
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Get started'),
      ),
    ],
  ),
);
