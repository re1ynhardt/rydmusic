import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

class NavItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  const NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });
}

/// Плавающая стеклянная нижняя навигация: выбранный пункт "раскрывается"
/// в градиентную капсулу с подписью, остальные остаются просто иконками —
/// без Material-подчёркиваний и жёстких границ на всю ширину экрана.
class PremiumNavBar extends StatelessWidget {
  const PremiumNavBar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<NavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, AppLayout.navBarBottomMargin),
      // Раньше панель растягивалась на всю доступную ширину (минус
      // боковые отступы Padding'а выше) — Center + FractionallySizedBox
      // сужают её примерно в 1.5 раза (widthFactor ≈ 1/1.5) и оставляют
      // по центру экрана, как компактную "капсулу", а не во всю ширину.
      child: Center(
        child: FractionallySizedBox(
          widthFactor: 0.66,
          child: RepaintBoundary(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                child: Container(
                  height: AppLayout.navBarHeight,
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceElevated.withOpacity(0.58),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(color: Colors.white.withOpacity(0.09)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.35),
                        blurRadius: 28,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Row(
                    children: List.generate(
                      items.length,
                      (i) => _NavBarItem(
                        item: items[i],
                        selected: i == selectedIndex,
                        onTap: () {
                          if (i != selectedIndex) {
                            HapticFeedback.selectionClick();
                          }
                          onSelect(i);
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavBarItem extends StatelessWidget {
  const _NavBarItem({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: AnimatedContainer(
            duration: Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.symmetric(
                horizontal: selected ? 14 : 10, vertical: 10),
            decoration: BoxDecoration(
              gradient: selected ? AppColors.accentGradient : null,
              borderRadius: BorderRadius.circular(18),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: AppColors.accentStart.withOpacity(0.38),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSwitcher(
                  duration: Duration(milliseconds: 200),
                  transitionBuilder: (child, anim) =>
                      ScaleTransition(scale: anim, child: child),
                  child: Icon(
                    selected ? item.selectedIcon : item.icon,
                    key: ValueKey(selected),
                    size: 22,
                    color: selected ? AppColors.onAccent : AppColors.textSecondary,
                  ),
                ),
                // Flexible, а не голый AnimatedSize: раньше на 4+ пунктах
                // навигации (после добавления вкладки "Главная") подпись
                // выбранного пункта требовала больше места, чем оставляла
                // ей Expanded-секция — Row не мог ужаться и вылезал за
                // границы панели (RenderFlex overflow). Flexible позволяет
                // Row'у выделить подписи ровно оставшееся место, а не то,
                // которое ей нужно по интринсик-ширине.
                Flexible(
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.centerLeft,
                    child: selected
                        ? Padding(
                            padding: const EdgeInsets.only(left: 7),
                            child: Text(
                              item.label,
                              // Если даже с Flexible подписи впритык не
                              // хватает места (мелкий экран, крупный
                              // системный шрифт) — многоточие вместо
                              // ошибки переполнения layout'а.
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                              style: TextStyle(
                                color: AppColors.onAccent,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.1,
                              ),
                            ),
                          )
                        : const SizedBox(height: 22),
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
