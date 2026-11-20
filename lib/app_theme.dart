import 'app_language.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Light and dark themes from one seed, and the person's choice (follow the phone, or always one).
const _seed = Color(0xFF087F8C);
const _key = 'theme_mode';

/// The chosen theme mode; the app rebuilds when it changes.
final appThemeMode = ValueNotifier<ThemeMode>(ThemeMode.system);

Future<void> loadThemeMode() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    appThemeMode.value = ThemeMode.values.asNameMap()[prefs.getString(_key) ?? ''] ?? ThemeMode.system;
  } catch (_) {}
}

Future<void> setThemeMode(ThemeMode mode) async {
  appThemeMode.value = mode;
  try {
    (await SharedPreferences.getInstance()).setString(_key, mode.name);
  } catch (_) {}
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  final page = dark ? const Color(0xFF0E161E) : const Color(0xFFF4F7FA);
  // One look for every screen: same title, flat bordered cards, same rows, sheets and dialogs.
  final ink = dark ? const Color(0xFFE4ECF2) : const Color(0xFF182D42);
  final card = dark ? const Color(0xFF17222D) : Colors.white;
  final border = dark ? const Color(0xFF2A3947) : const Color(0xFFDDE5EC);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: page,
    appBarTheme: AppBarTheme(
      backgroundColor: page,
      foregroundColor: dark ? scheme.onSurface : const Color(0xFF182D42),
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: ink),
    ),
    cardTheme: CardThemeData(
      color: card,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: border)),
      clipBehavior: Clip.antiAlias,
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      iconColor: dark ? scheme.onSurfaceVariant : const Color(0xFF4A5D6E),
      titleTextStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: ink),
      subtitleTextStyle: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
    ),
    dividerTheme: DividerThemeData(color: border, space: 1),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: card, showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24)))),
    dialogTheme: DialogThemeData(backgroundColor: card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    popupMenuTheme: PopupMenuThemeData(color: card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    inputDecorationTheme: InputDecorationTheme(
      helperMaxLines: 4,
      errorMaxLines: 4,
      filled: true,
      fillColor: dark ? scheme.surfaceContainerHigh : Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: dark ? scheme.outlineVariant : const Color(0xFFD8E2E9)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
      minimumSize: const Size(48, 52),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    )),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
      minimumSize: const Size(48, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    )),
  );
}

/// Colors with a meaning, right in light and dark (use these instead of fixed light-only colors).
extension AppColors on BuildContext {
  ColorScheme get cs => Theme.of(this).colorScheme;
  bool get isDark => Theme.of(this).brightness == Brightness.dark;

  /// Cards and list rows that sit on the page background.
  Color get card => isDark ? const Color(0xFF17222D) : Colors.white;
  Color get cardDisabled => isDark ? const Color(0xFF121B24) : const Color(0xFFE9EEF2);
  Color get border => isDark ? const Color(0xFF2A3947) : const Color(0xFFDDE5EC);
  Color get page => Theme.of(this).scaffoldBackgroundColor;

  /// Headings and body text, and secondary text.
  Color get ink => isDark ? const Color(0xFFE4ECF2) : const Color(0xFF182D42);
  Color get muted => cs.onSurfaceVariant;
}

/// A small control to choose System / Light / Dark.
/// Light, dark or like the phone, as a small dialog (from a menu).
Future<void> chooseThemeMode(BuildContext context) async {
  final picked = await showDialog<ThemeMode>(context: context, builder: (context) => SimpleDialog(
    title: Text(context.strings.appearance),
    children: [
      for (final (mode, label) in [(ThemeMode.system, context.strings.systemTheme), (ThemeMode.light, context.strings.lightTheme),
          (ThemeMode.dark, context.strings.darkTheme)])
        ListTile(key: Key('theme-${mode.name}'), title: Text(label),
          trailing: appThemeMode.value == mode ? const Icon(Icons.check) : null,
          onTap: () => Navigator.pop(context, mode)),
    ],
  ));
  if (picked != null) await setThemeMode(picked);
}

class ThemeModeButton extends StatelessWidget {
  const ThemeModeButton({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
    valueListenable: appThemeMode,
    builder: (context, mode, _) => PopupMenuButton<ThemeMode>(
      key: const Key('theme-mode'),
      tooltip: context.strings.appearance,
      initialValue: mode,
      icon: Icon(switch (mode) {
        ThemeMode.light => Icons.light_mode_outlined,
        ThemeMode.dark => Icons.dark_mode_outlined,
        ThemeMode.system => Icons.brightness_auto_outlined,
      }),
      onSelected: setThemeMode,
      itemBuilder: (_) => [
        PopupMenuItem(value: ThemeMode.system, child: Text(context.strings.systemTheme)),
        PopupMenuItem(value: ThemeMode.light, child: Text(context.strings.lightTheme)),
        PopupMenuItem(value: ThemeMode.dark, child: Text(context.strings.darkTheme)),
      ],
    ),
  );
}
