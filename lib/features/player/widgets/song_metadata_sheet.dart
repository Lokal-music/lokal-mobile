import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/models/song.dart';
import 'package:flick/widgets/common/glass_bottom_sheet.dart';
import 'package:flick/l10n/l10n.dart';

/// Audio source names come from the selected provider, not its media URL.
/// Content length is only shown if the actual rendition reports its bytes.
String metadataSourceLabel(Song song) {
  final configured = song.sourceDisplayName?.trim();
  if (configured != null && configured.isNotEmpty) return configured;
  if (song.sourcePackage == 'konnekted.morneye-live') return 'Morneye';
  if (song.sourcePackage == 'konnekted.progressive') return 'HTTP add-on';
  if (song.sourcePackage == 'konnekted.discovery') return 'Online source';
  final source = song.sourceType?.trim();
  if (source != null && source.isNotEmpty) {
    return switch (source.toLowerCase()) {
      'subsonic' => 'Subsonic / Navidrome',
      'jellyfin' => 'Jellyfin',
      'webdav' => 'WebDAV',
      _ => source,
    };
  }
  return song.isExternal ? 'External source' : 'Local file';
}

String? metadataFileSizeMb(int? bytes) =>
    bytes != null && bytes > 0
        ? '${(bytes / 1000000).toStringAsFixed(2)} MB'
        : null;

/// Local files can be measured without network activity. Opaque Morneye and
/// progressive handles are not ordinary paths and must never be stat'ed.
Future<int?> metadataFileBytes(Song song) async {
  if (song.fileSizeBytes case final known? when known > 0) return known;
  final path = song.filePath;
  if (path == null || path.isEmpty ||
      path.contains('://') || song.isNetworkSource) return null;
  try {
    final file = File(path);
    final size = await file.length();
    return size > 0 ? size : null;
  } on FileSystemException {
    return null;
  }
}

class SongMetadataSheet extends StatelessWidget {
  final Song song;
  const SongMetadataSheet({super.key, required this.song});

  static Future<void> show(BuildContext context, Song song) {
    return showModalBottomSheet(
      useRootNavigator: true,
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => SongMetadataSheet(song: song),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppBottomSheetSurface.decoration,
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.info,
                size: 20,
                color: context.adaptiveTextSecondary,
              ),
              const SizedBox(width: 10),
              Text(
                l10n.songMetadata,
                style: TextStyle(
                  fontFamily: 'GoogleSansFlex',
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: context.adaptiveTextPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildMetadataRow(context, l10n.title, song.title),
          _buildMetadataRow(context, l10n.artist, song.artist),
          if (song.album != null)
            _buildMetadataRow(context, l10n.album, song.album!),
          _buildMetadataRow(context, l10n.duration, song.formattedDuration),
          _buildMetadataRow(context, 'Source', metadataSourceLabel(song)),
          FutureBuilder<int?>(
            future: metadataFileBytes(song),
            builder: (context, snapshot) => _buildMetadataRow(
              context, 'File size',
              metadataFileSizeMb(snapshot.data) ?? 'Not available',
            ),
          ),
          _buildMetadataRow(
            context,
            l10n.format,
            song.isDsd
                ? '${song.fileType.toUpperCase()} (${song.dsdRateLabel})'
                : song.fileType.toUpperCase(),
          ),
          if (song.atmosEncoded)
            _buildMetadataRow(
              context, 'Spatial audio source', 'Dolby Atmos (verified E-AC-3 JOC)',
            ),
          if (song.resolution != null && !song.isDsd)
            _buildMetadataRow(context, l10n.resolution, song.resolution!),
          if (song.albumArtist != null)
            _buildMetadataRow(context, l10n.albumArtist, song.albumArtist!),
          if (song.genre != null)
            _buildMetadataRow(context, l10n.genre, song.genre!),
          if (song.year != null)
            _buildMetadataRow(context, l10n.year, song.year!.toString()),
          if (song.trackNumber != null)
            _buildMetadataRow(
              context,
              l10n.track,
              song.trackNumber!.toString(),
            ),
          if (song.discNumber != null)
            _buildMetadataRow(context, l10n.disc, song.discNumber!.toString()),
          if (song.filePath != null)
            _buildMetadataRow(context, l10n.filePath, song.filePath!),
        ],
      ),
    );
  }

  Widget _buildMetadataRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'GoogleSansFlex',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.adaptiveTextSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontFamily: 'GoogleSansFlex',
                fontSize: 13,
                color: context.adaptiveTextPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
