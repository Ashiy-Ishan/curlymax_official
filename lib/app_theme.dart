import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppAppearance extends ValueNotifier<ThemeMode> {
  AppAppearance(this.prefs)
    : super(
        ThemeMode.values.firstWhere(
          (mode) => mode.name == prefs.getString('appearance'),
          orElse: () => ThemeMode.system,
        ),
      );
  final SharedPreferences prefs;
  Future<void> select(ThemeMode mode) async {
    await prefs.setString('appearance', mode.name);
    value = mode;
  }
}

ThemeData curlyTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF99C1DE),
        brightness: brightness,
      ).copyWith(
        primary: dark ? const Color(0xFF99C1DE) : const Color(0xFF285578),
        onPrimary: dark ? const Color(0xFF122D40) : Colors.white,
        primaryContainer: const Color(0xFFBCD4E6),
        onPrimaryContainer: const Color(0xFF162E40),
        secondary: dark ? const Color(0xFFC5DEDD) : const Color(0xFF365F5D),
        secondaryContainer: const Color(0xFFC5DEDD),
        onSecondaryContainer: const Color(0xFF183837),
        tertiary: dark ? const Color(0xFFFAD2E1) : const Color(0xFF7A4059),
        tertiaryContainer: const Color(0xFFFDE2E4),
        onTertiaryContainer: const Color(0xFF492234),
        surface: dark ? const Color(0xFF121820) : const Color(0xFFFFF1E6),
        onSurface: dark ? const Color(0xFFF0EFEB) : const Color(0xFF202C36),
        onSurfaceVariant: dark
            ? const Color(0xFFBCD4E6)
            : const Color(0xFF4A5963),
        surfaceContainerLow: dark
            ? const Color(0xFF1D2833)
            : const Color(0xFFF0EFEB),
        surfaceContainer: dark
            ? const Color(0xFF253442)
            : const Color(0xFFDBE7E4),
        surfaceContainerHigh: dark
            ? const Color(0xFF2D3C48)
            : const Color(0xFFD6E2E9),
        outline: dark ? const Color(0xFF879CA8) : const Color(0xFF65737C),
        outlineVariant: dark
            ? const Color(0xFF425563)
            : const Color(0xFFEDDCD2),
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    textTheme: const TextTheme(
      headlineLarge: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -1),
      headlineMedium: TextStyle(fontWeight: FontWeight.w700),
      titleLarge: TextStyle(fontWeight: FontWeight.w700),
    ),
  );
}

class AppearanceScope extends InheritedNotifier<AppAppearance> {
  const AppearanceScope({
    super.key,
    required AppAppearance appearance,
    required super.child,
  }) : super(notifier: appearance);
  static AppAppearance? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;
}

class AppearancePicker extends StatelessWidget {
  const AppearancePicker({super.key});
  @override
  Widget build(BuildContext context) {
    final appearance = AppearanceScope.of(context);
    if (appearance == null) return const SizedBox.shrink();
    return ListTile(
      leading: const Icon(Icons.palette_outlined),
      title: const Text('Appearance'),
      trailing: DropdownButton<ThemeMode>(
        value: appearance.value,
        onChanged: (mode) {
          if (mode != null) appearance.select(mode);
        },
        items: const [
          DropdownMenuItem(value: ThemeMode.system, child: Text('System')),
          DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
          DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
        ],
      ),
    );
  }
}
