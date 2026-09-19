import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Доступные темы приложения: стандартная (чёрный фон, белые акценты)
/// и белая (светлый фон, тёмный текст).
enum AppThemeMode { dark, light }

/// Палитра и типографика в духе Apple Music: много воздуха,
/// скруглённые карточки и мягкие тени вместо жёстких границ.
///
/// Значения — не `const`, а геттеры поверх текущего [AppThemeMode],
/// поэтому весь экран, использующий `AppColors.xxx`, подхватывает новую
/// палитру сразу после смены темы и перерисовки дерева виджетов —
/// без ручной правки цвета в каждом виджете.
class AppColors {
  AppColors._();

  static AppThemeMode _mode = AppThemeMode.dark;
  static AppThemeMode get mode => _mode;

  /// Вызывается из ThemeProvider при смене темы, до перестроения UI.
  static void setMode(AppThemeMode mode) => _mode = mode;

  static bool get _isDark => _mode == AppThemeMode.dark;

  static Color get background =>
      _isDark ? const Color(0xFF0A0A0C) : const Color(0xFFF7F7F9);
  static Color get surface =>
      _isDark ? const Color(0xFF161618) : const Color(0xFFFFFFFF);
  static Color get surfaceElevated =>
      _isDark ? const Color(0xFF1F1F22) : const Color(0xFFEDEDF0);
  static Color get textPrimary =>
      _isDark ? const Color(0xFFF5F5F7) : const Color(0xFF15151A);
  static Color get textSecondary =>
      _isDark ? const Color(0xFF9A9AA2) : const Color(0xFF6E6E76);

  // Акцент: раньше был красно-розовый градиент, по требованию сделан
  // белым/светло-серым в тёмной теме и тёмным/чёрным — в белой, чтобы
  // акцентные элементы оставались контрастны фону в обеих темах.
  static Color get accentStart =>
      _isDark ? const Color(0xFFFFFFFF) : const Color(0xFF1A1A1E);
  static Color get accentEnd =>
      _isDark ? const Color(0xFFD8D8DE) : const Color(0xFF3A3A40);

  /// Цвет содержимого (иконки/текста), которое рисуется ПОВЕРХ
  /// accentGradient/accentStart-заливки — не сам акцент. Нужен отдельно,
  /// потому что акцент теперь светлый в тёмной теме: если положить поверх
  /// него текст/иконку старого фиксированного белого цвета, они сольются
  /// с фоном. Здесь всегда обратный к акценту контраст.
  static Color get onAccent => _isDark ? Colors.black : Colors.white;

  static LinearGradient get accentGradient => LinearGradient(
        colors: [accentStart, accentEnd],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
}

/// Геометрия плавающего мини-плеера + нижней навигации (см. MainShell) —
/// в одном месте, чтобы списки на разных экранах могли резервировать под
/// них ровно столько места снизу, сколько нужно, и не более того.
class AppLayout {
  static const double navBarHeight = 66;
  static const double navBarBottomMargin = 10;
  static const double miniPlayerHeight = 64;
  static const double barSpacing = 4;
  static const double listBottomBreathingRoom = 16;

  /// Сколько пикселей внизу списка нужно оставить пустыми, чтобы последний
  /// элемент полностью выезжал из-под плавающей панели при скролле.
  static double reservedBottomSpace({required bool hasMiniPlayer}) {
    final navTotal = navBarHeight + navBarBottomMargin;
    final miniPlayerTotal =
        hasMiniPlayer ? miniPlayerHeight + barSpacing : 0.0;
    return navTotal + miniPlayerTotal + listBottomBreathingRoom;
  }
}

class AppTheme {
  /// Общий ThemeData для обеих тем — различие только в палитре и
  /// яркости базовой Material-темы, geometry/типографика те же.
  static ThemeData _build({required Brightness brightness}) {
    final base = brightness == Brightness.dark
        ? ThemeData.dark(useMaterial3: true)
        : ThemeData.light(useMaterial3: true);
    final textTheme = GoogleFonts.interTextTheme(base.textTheme).apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    );

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      textTheme: textTheme,
      colorScheme: base.colorScheme.copyWith(
        brightness: brightness,
        primary: AppColors.accentStart,
        secondary: AppColors.accentEnd,
        surface: AppColors.surface,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        scrolledUnderElevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.surface.withOpacity(0.92),
        elevation: 0,
        height: 64,
        indicatorColor: AppColors.accentStart.withOpacity(0.18),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? AppColors.textPrimary : AppColors.textSecondary,
          );
        }),
      ),
      splashFactory: InkSparkle.splashFactory,
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      }),
    );
  }

  /// Стандартная тёмная тема — чёрный фон, белые акцентные элементы.
  static ThemeData get dark => _build(brightness: Brightness.dark);

  /// Белая тема — светлый фон, тёмный текст и тёмные акценты.
  static ThemeData get light => _build(brightness: Brightness.light);

  static ThemeData forMode(AppThemeMode mode) =>
      mode == AppThemeMode.dark ? dark : light;
}
