import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/cached_tracks_provider.dart';
import '../providers/language_provider.dart';
import '../theme/app_theme.dart';
import 'app_dialog_shell.dart';

/// Человекочитаемый размер: "0 Б", "412 КБ", "1.3 ГБ" и т.п.
String formatBytes(int bytes) {
  // Единицы — на текущем языке интерфейса (AppStrings.current).
  final units = AppStrings.current.byteUnits;
  if (bytes <= 0) return '0 ${units[0]}';
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  final formatted = unitIndex == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$formatted ${units[unitIndex]}';
}

/// Открывает шит "Кэш и офлайн": показывает сколько треков закэшировано
/// и сколько места они занимают, с кнопкой полной очистки.
Future<void> showCacheSettingsSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const _CacheSettingsSheet(),
  );
}

class _CacheSettingsSheet extends StatefulWidget {
  const _CacheSettingsSheet();

  @override
  State<_CacheSettingsSheet> createState() => _CacheSettingsSheetState();
}

class _CacheSettingsSheetState extends State<_CacheSettingsSheet> {
  bool _clearing = false;

  Future<void> _confirmAndClear() async {
    final l10n = AppStrings.current;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialogShell(
        icon: Icons.delete_sweep_rounded,
        iconColor: const Color(0xFFFF5B5B),
        title: l10n.deleteCacheQuestion,
        content: Text(
          l10n.deleteCacheBody,
          style: TextStyle(color: AppColors.textSecondary, height: 1.4),
        ),
        cancelLabel: l10n.cancel,
        confirmLabel: l10n.delete,
        confirmColor: const Color(0xFFFF5B5B),
        onConfirm: () => Navigator.of(dialogContext).pop(true),
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _clearing = true);
    await context.read<CachedTracksProvider>().clearAll();
    if (!mounted) return;
    setState(() => _clearing = false);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cache = context.watch<CachedTracksProvider>();
    final hasCache = cache.count > 0;

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
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              l10n.cacheOffline,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _StatColumn(
                      label: l10n.cacheTracks,
                      value: '${cache.count}',
                    ),
                  ),
                  Container(
                    width: 1,
                    height: 32,
                    color: AppColors.surface,
                  ),
                  Expanded(
                    child: _StatColumn(
                      label: l10n.cacheSpaceUsed,
                      value: formatBytes(cache.totalSizeBytes),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: !hasCache || _clearing ? null : _confirmAndClear,
                icon: _clearing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.delete_sweep_rounded, size: 20),
                label: Text(_clearing ? l10n.deleting : l10n.deleteAllCache),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF5B5B),
                  disabledBackgroundColor:
                      const Color(0xFFFF5B5B).withOpacity(0.35),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            if (!hasCache) ...[
              const SizedBox(height: 10),
              Text(
                l10n.cacheEmpty,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatColumn extends StatelessWidget {
  const _StatColumn({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
        ),
      ],
    );
  }
}
