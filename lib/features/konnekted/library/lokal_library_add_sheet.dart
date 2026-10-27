import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flutter/material.dart';

/// Actions from Library's add menu. Kept separate from routing so the modal
/// closes completely before the selected action launches another route or
/// Android's document/folder picker.
enum LokalLibraryAddAction { playlist, link, m3u, folder }

Future<LokalLibraryAddAction?> showLokalLibraryAddSheet(
  BuildContext context,
) {
  final t = context.lokal;
  return showModalBottomSheet<LokalLibraryAddAction>(
    context: context,
    useRootNavigator: true,
    backgroundColor: t.surface,
    showDragHandle: true,
    builder: (sheetContext) {
      Widget row(IconData icon, String label, LokalLibraryAddAction action) =>
          ListTile(
            leading: Icon(icon, color: t.accent),
            title: Text(lokalText(label)),
            onTap: () => Navigator.of(sheetContext).pop(action),
          );

      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            row(Icons.queue_music_rounded, 'New playlist',
                LokalLibraryAddAction.playlist),
            row(Icons.link_rounded, 'Import a playlist link',
                LokalLibraryAddAction.link),
            row(Icons.playlist_add_rounded, 'Import M3U',
                LokalLibraryAddAction.m3u),
            row(Icons.create_new_folder_rounded, 'Add a music folder',
                LokalLibraryAddAction.folder),
          ],
        ),
      );
    },
  );
}
