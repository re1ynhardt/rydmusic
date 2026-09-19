import 'package:flutter/material.dart';

/// Ключ корневого Navigator'а приложения.
///
/// Нужен строго для виджетов, физически расположенных ВНЕ поддерева
/// Navigator'а — например, глобальный мини-плеер в main.dart рисуется
/// через MaterialApp.builder как SIBLING (а не потомок) самого
/// Navigator'а, чтобы оставаться поверх любого запушенного экрана.
/// Из-за этого `Navigator.of(context)` изнутри него не находит предка
/// (поиск идёт вверх по дереву, а не вбок) — вместо этого пушим через
/// `rootNavigatorKey.currentState`.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
