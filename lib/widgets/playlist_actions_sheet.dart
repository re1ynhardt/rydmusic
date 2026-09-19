import 'package:flutter/material.dart';

import '../providers/language_provider.dart';
import '../theme/app_theme.dart';
import 'app_dialog_shell.dart';

/// Красивый боттом-шит с действиями над плейлистом: переименовать,
/// сменить обложку, удалить. Каждое действие — крупная строка с цветной
/// иконкой в кружке, удаление визуально выделено красным.
Future<void> showPlaylistActionsSheet(
  BuildContext context, {
  required VoidCallback onRename,
  required VoidCallback onChangeCover,
  required VoidCallback onDelete,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => _PlaylistActionsSheet(
      onRename: onRename,
      onChangeCover: onChangeCover,
      onDelete: onDelete,
    ),
  );
}

class _PlaylistActionsSheet extends StatelessWidget {
  const _PlaylistActionsSheet({
    required this.onRename,
    required this.onChangeCover,
    required this.onDelete,
  });

  final VoidCallback onRename;
  final VoidCallback onChangeCover;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.18),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            _ActionRow(
              icon: Icons.edit_rounded,
              iconColor: AppColors.textPrimary,
              label: l10n.rename,
              onTap: () {
                Navigator.of(context).pop();
                onRename();
              },
            ),
            _ActionRow(
              icon: Icons.image_rounded,
              iconColor: AppColors.textPrimary,
              label: l10n.changeCover,
              onTap: () {
                Navigator.of(context).pop();
                onChangeCover();
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Divider(height: 1, color: AppColors.surfaceElevated),
            ),
            _ActionRow(
              icon: Icons.delete_rounded,
              iconColor: const Color(0xFFFF5B5B),
              labelColor: const Color(0xFFFF5B5B),
              label: l10n.deletePlaylist,
              onTap: () {
                Navigator.of(context).pop();
                onDelete();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.onTap,
    this.labelColor,
  });

  final IconData icon;
  final Color iconColor;
  final Color? labelColor;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: iconColor, size: 20),
              ),
              const SizedBox(width: 14),
              Text(
                label,
                style: TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w600,
                  color: labelColor ?? AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Диалог переименования с аккуратным полем ввода и акцентной кнопкой
/// подтверждения. Возвращает новое имя, либо null при отмене.
Future<String?> showRenamePlaylistDialog(
  BuildContext context, {
  required String currentName,
}) {
  final controller = TextEditingController(text: currentName);
  final l10n = AppStrings.current;
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AppDialogShell(
      icon: Icons.edit_rounded,
      iconColor: AppColors.textPrimary,
      title: l10n.renamePlaylist,
      content: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 60,
            style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(
              counterText: '',
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 12),
            ),
            onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
          ),
        ),
      ),
      cancelLabel: l10n.cancel,
      confirmLabel: l10n.save,
      onConfirm: () => Navigator.of(dialogContext).pop(controller.text),
    ),
  );
}

/// Диалог подтверждения удаления плейлиста — акцентная кнопка красная,
/// чтобы деструктивное действие визуально выделялось.
Future<bool> showDeletePlaylistDialog(BuildContext context) async {
  final l10n = AppStrings.current;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AppDialogShell(
      icon: Icons.delete_rounded,
      iconColor: const Color(0xFFFF5B5B),
      title: l10n.deletePlaylistQuestion,
      content: Text(
        l10n.deletePlaylistBody,
        style: TextStyle(color: AppColors.textSecondary, height: 1.4),
      ),
      cancelLabel: l10n.cancel,
      confirmLabel: l10n.delete,
      confirmColor: const Color(0xFFFF5B5B),
      onConfirm: () => Navigator.of(dialogContext).pop(true),
    ),
  );
  return confirmed ?? false;
}
