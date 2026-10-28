import 'package:flick/l10n/l10n.dart';
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
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(LucideIcons.download),
                title: Text(lokalText('Save original lyrics')),
                onTap: () {
                  Navigator.pop(sheetContext);
                  onSaveOriginal();
                },
              ),
              ListTile(
                leading: const Icon(Icons.translate_rounded),
                title: Text(lokalText('Save with selected translation')),
                subtitle: Text(
                  lokalText('Includes the active translation or romanization.'),
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
  Widget build(BuildContext context) => Tooltip(
    message: lokalText('Save lyrics to file (hold for options)'),
    // IconButton's default long-press Tooltip competes in the gesture
    // arena and can swallow the long-press that should open this menu.
    // Manual mode retains hover/semantics without a touch recognizer.
    triggerMode: TooltipTriggerMode.manual,
    child: GestureDetector(
      onLongPress: saving ? null : () => _showOptions(context),
      child: IconButton(
        visualDensity: VisualDensity.standard,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        icon: saving
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(LucideIcons.download, color: iconColor, size: 19),
        onPressed: saving ? null : onSaveOriginal,
      ),
    ),
  );
}
