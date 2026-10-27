import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Tap saves the original lyric document. Long-press offers an explicit
/// translated/romanized export, without changing the normal save action.
class LyricsSaveButton extends StatelessWidget {
  const LyricsSaveButton({
    super.key,
    required this.saving,
    required this.onSaveOriginal,
    this.onSaveWithTranslation,
    this.iconColor,
  });

  final bool saving;
  final VoidCallback onSaveOriginal;
  final VoidCallback? onSaveWithTranslation;
  final Color? iconColor;

  void _showOptions(BuildContext context) {
    if (saving) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(LucideIcons.download),
                title: const Text('Save original lyrics'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  onSaveOriginal();
                },
              ),
              ListTile(
                leading: const Icon(Icons.translate_rounded),
                title: const Text('Save with selected translation'),
                subtitle: const Text(
                  'Includes the active translation or romanization.',
                ),
                enabled: onSaveWithTranslation != null,
                onTap: onSaveWithTranslation == null
                    ? null
                    : () {
                        Navigator.pop(sheetContext);
                        onSaveWithTranslation!();
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onLongPress: saving ? null : () => _showOptions(context),
    child: IconButton(
      tooltip: 'Save lyrics to file (hold for options)',
      visualDensity: VisualDensity.compact,
      icon: saving
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(LucideIcons.download, color: iconColor, size: 19),
      onPressed: saving ? null : onSaveOriginal,
    ),
  );
}
