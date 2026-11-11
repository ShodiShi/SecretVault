import 'package:flutter/material.dart';

import '../models/vault_item.dart';

abstract final class AppColors {
  static const seed = Color(0xFF7C5CFF);
  static const gradientStart = Color(0xFF8B5CF6);
  static const gradientEnd = Color(0xFF22D3EE);

  static const accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [gradientStart, gradientEnd],
  );

  static Color forType(ItemType type) => switch (type) {
        ItemType.password => const Color(0xFF9B8CFF),
        ItemType.server => const Color(0xFF34D399),
        ItemType.note => const Color(0xFFFBBF24),
        ItemType.task => const Color(0xFF60A5FA),
      };

  static Color forPriority(TaskPriority priority) => switch (priority) {
        TaskPriority.low => const Color(0xFF34D399),
        TaskPriority.medium => const Color(0xFFFBBF24),
        TaskPriority.high => const Color(0xFFF87171),
      };

  static const strength = [
    Color(0xFFF87171),
    Color(0xFFFB923C),
    Color(0xFFFBBF24),
    Color(0xFF4ADE80),
    Color(0xFF22D3EE),
  ];
}

IconData iconForType(ItemType type) => switch (type) {
      ItemType.password => Icons.key_rounded,
      ItemType.server => Icons.dns_rounded,
      ItemType.note => Icons.sticky_note_2_rounded,
      ItemType.task => Icons.task_alt_rounded,
    };

String typeLabel(ItemType type) => switch (type) {
      ItemType.password => 'Пароль',
      ItemType.server => 'Сервер',
      ItemType.note => 'Секретная заметка',
      ItemType.task => 'Задача',
    };

String priorityLabel(TaskPriority priority) => switch (priority) {
      TaskPriority.low => 'Низкий',
      TaskPriority.medium => 'Средний',
      TaskPriority.high => 'Высокий',
    };

/// Моноширинный стиль для паролей, адресов и команд (системные шрифты).
const monoStyle = TextStyle(
  fontFamily: 'Consolas',
  fontFamilyFallback: ['Roboto Mono', 'monospace'],
  letterSpacing: 0.3,
);

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.seed,
    brightness: brightness,
  ).copyWith(
    surface: dark ? const Color(0xFF0F1118) : const Color(0xFFF7F7FC),
    surfaceContainerLowest:
        dark ? const Color(0xFF0B0D13) : const Color(0xFFFFFFFF),
    surfaceContainerLow:
        dark ? const Color(0xFF151823) : const Color(0xFFFFFFFF),
    surfaceContainer: dark ? const Color(0xFF1A1E2B) : const Color(0xFFF0F0F8),
    surfaceContainerHigh:
        dark ? const Color(0xFF222738) : const Color(0xFFE9E9F4),
    surfaceContainerHighest:
        dark ? const Color(0xFF2A3044) : const Color(0xFFE2E2EF),
  );
  final radius14 = BorderRadius.circular(14);

  return ThemeData(
    colorScheme: scheme,
    brightness: brightness,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.standard,
    splashFactory: InkSparkle.splashFactory,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainer,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: radius14,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius14,
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius14,
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: radius14,
        borderSide: BorderSide(color: scheme.error, width: 1.2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: radius14,
        borderSide: BorderSide(color: scheme.error, width: 1.6),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: radius14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: radius14),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      side: BorderSide.none,
      backgroundColor: scheme.surfaceContainer,
      selectedColor: scheme.primaryContainer,
      showCheckmark: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      height: 68,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      indicatorColor: scheme.primaryContainer,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: radius14),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.4),
      thickness: 1,
      space: 1,
    ),
  );
}
