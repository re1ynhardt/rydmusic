import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Держит факт: должен ли сейчас прятаться глобальный мини-плеер (см.
/// main.dart). Он рисуется как SIBLING самого Navigator'а внутри
/// MaterialApp.builder (см. комментарий в navigation.dart), а не его
/// потомком — поэтому сам по себе ничего не знает ни про полноэкранный
/// NowPlayingScreen, ни про любые bottom sheet'ы/диалоги, запушенные
/// в тот же Navigator, и рисуется поверх них, если явно не спрятать.
/// Прятать нужно в обоих случаях:
/// - открыт NowPlayingScreen (тот же трек показан полноэкранно);
/// - открыт любой modal bottom sheet или диалог (переименование
///   плейлиста, смена аватарки, подтверждение удаления и т.п.) —
///   иначе мини-плеер лежит поверх части этого окна.
class NowPlayingVisibility extends ChangeNotifier {
  bool _fullScreenOpen = false;
  int _popupCount = 0;

  bool get isOpen => _fullScreenOpen || _popupCount > 0;

  void setOpen(bool value) {
    if (_fullScreenOpen == value) return;
    final was = isOpen;
    _fullScreenOpen = value;
    if (isOpen != was) _notifySafely();
  }

  /// Сколько модальных окон сейчас открыто — считает наблюдатель ниже.
  void _setPopupCount(int count) {
    if (_popupCount == count) return;
    final was = isOpen;
    _popupCount = count;
    if (isOpen != was) _notifySafely();
  }

  /// Уведомление может прилететь из середины кадра: push/pop роутов
  /// иногда происходит внутри build/layout (например, роут закрывается
  /// по результату перестроения дерева). notifyListeners() в этот момент
  /// бросает исключение "setState() called during build", а вместе с ним
  /// теряется и сам факт закрытия окна — мини-плеер после этого остаётся
  /// спрятанным навсегда. Поэтому в фазе построения кадра откладываем
  /// уведомление до его конца.
  void _notifySafely() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    final inFrame = phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks;
    if (inFrame) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Ловит push/pop любых роутов рутового Navigator'а и обновляет
/// [NowPlayingVisibility]:
/// - роут с именем [routeName] (сам NowPlayingScreen) — прячет плеер на
///   время своей жизни;
/// - любой [PopupRoute] (это и есть база для bottom sheet'ов и
///   диалогов — ModalBottomSheetRoute и DialogRoute оба от него
///   наследуются) — пока открыт хотя бы один.
///
/// ВАЖНО, как это устроено. Раньше здесь был простой счётчик +/-1 по
/// событиям didPush/didPop/didRemove/didReplace. У такой схемы есть
/// дыра: стоит одному закрытию потеряться (окно снято не через те
/// события, наблюдатель отцеплен от Navigator'а в момент закрытия,
/// уведомление упало с исключением) — и счётчик навсегда остаётся
/// положительным, а мини-плеер навсегда невидимым. Пользователь видит
/// ровно то же, что и в баг-репорте: "то есть, то нет".
///
/// Теперь вместо счётчика — множество живых роутов (повторный push того
/// же роута ничего не ломает, лишний pop тоже), а на каждый роут
/// дополнительно вешается его собственный `popped`-future. Этот future
/// завершается при ЛЮБОМ способе снятия роута со стека, так что даже
/// если событие наблюдателя потерялось, запись всё равно вычистится, и
/// состояние само себя починит.
class NowPlayingRouteObserver extends NavigatorObserver {
  NowPlayingRouteObserver(this.visibility);
  final NowPlayingVisibility visibility;

  static const routeName = '/now-playing';

  final Set<Route<dynamic>> _popups = <Route<dynamic>>{};
  Route<dynamic>? _fullScreen;

  bool _matches(Route<dynamic>? route) => route?.settings.name == routeName;

  /// Подписка на снятие роута со стека — срабатывает при любом способе
  /// закрытия, включая те, о которых наблюдателю не сообщили.
  void _watchClose(Route<dynamic> route) {
    route.popped.then<void>(
      (_) => _trackClosed(route),
      onError: (Object _, StackTrace __) => _trackClosed(route),
    );
  }

  void _trackOpened(Route<dynamic> route) {
    if (_matches(route)) {
      _fullScreen = route;
      visibility.setOpen(true);
      _watchClose(route);
      return;
    }
    if (route is PopupRoute && _popups.add(route)) {
      _watchClose(route);
      visibility._setPopupCount(_popups.length);
    }
  }

  void _trackClosed(Route<dynamic>? route) {
    if (route == null) return;
    // Сверка именно по идентичности объекта: пока закрывается старый
    // полноэкранный плеер, пользователь мог уже открыть новый — гасить
    // видимость из-за старого роута нельзя.
    if (identical(_fullScreen, route)) {
      _fullScreen = null;
      visibility.setOpen(false);
      return;
    }
    if (_popups.remove(route)) {
      visibility._setPopupCount(_popups.length);
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _trackOpened(route);
    // Снимаем фокус с любого текстового поля при КАЖДОМ переходе.
    // Нужно из-за того, что глобальный мини-плеер (см. main.dart) теперь
    // живёт в MaterialApp.builder — один и тот же виджет на весь стек
    // экранов — и если пуш происходит, пока в поле поиска ещё не
    // завершён ввод (активен composing-регион от IME/автокоррекции),
    // Flutter продолжает рисовать его цветное подчёркивание даже когда
    // само поле уже не видно, и оно "прилипает" к другому тексту на
    // экране вместо того, чтобы просто исчезнуть вместе со старым
    // экраном (как было раньше, когда мини-плеер каждый раз пересоздавался
    // внутри конкретного экрана и не переживал переход).
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _trackClosed(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _trackClosed(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _trackClosed(oldRoute);
    if (newRoute != null) _trackOpened(newRoute);
  }
}
