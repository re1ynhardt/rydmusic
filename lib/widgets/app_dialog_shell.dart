import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Общая «рамка» диалога подтверждения: иконка в кружке сверху, заголовок,
/// произвольный контент, две кнопки внизу (текстовая отмена + акцентная
/// заполненная подтверждение). Вынесено из playlist_actions_sheet.dart,
/// чтобы использовать тот же вид для любых других диалогов подтверждения
/// в приложении (например, очистка кэша в настройках).
class AppDialogShell extends StatelessWidget {
  const AppDialogShell({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.content,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.onConfirm,
    this.confirmColor,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final Widget content;
  final String cancelLabel;
  final String confirmLabel;
  final Color? confirmColor;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final accent = confirmColor ?? AppColors.accentStart;
    final onAccent = confirmColor != null ? Colors.white : AppColors.onAccent;
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 24),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            content,
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 46,
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textSecondary,
                        side: BorderSide(color: AppColors.surfaceElevated),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(cancelLabel,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 46,
                    child: ElevatedButton(
                      onPressed: onConfirm,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: onAccent,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(confirmLabel,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
