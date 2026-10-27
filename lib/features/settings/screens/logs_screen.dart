import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flick/core/theme/app_theme.dart';
import 'package:flick/core/utils/app_haptics.dart';
import 'package:flick/core/utils/app_log.dart';
import 'package:flick/widgets/common/display_mode_wrapper.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';

class LogsScreen extends ConsumerStatefulWidget {
  const LogsScreen({super.key});

  @override
  ConsumerState<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends ConsumerState<LogsScreen> {
  final ScrollController _ctrl = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  final Set<LogSource> _sources = {};
  bool _stickToBottom = true;
  bool _isUploading = false;

  @override
  void dispose() {
    _ctrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  List<LogEntry> _filtered(List<LogEntry> all) {
    var result = all;
    if (_sources.isNotEmpty) {
      result = result
          .where((e) => _sources.contains(e.source))
          .toList(growable: false);
    }
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      result = result
          .where((e) => e.message.toLowerCase().contains(q))
          .toList(growable: false);
    }
    return result;
  }

  void _stickIfWanted() {
    if (!_stickToBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_ctrl.hasClients) return;
      _ctrl.jumpTo(_ctrl.position.maxScrollExtent);
    });
  }

  String _ts(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.'
      '${t.millisecond.toString().padLeft(3, '0')}';

  String _format(LogEntry e) =>
      '${_ts(e.timestamp)} [${e.source.name}] ${e.message}';

  String get _subject => 'Lokal logs';

  Color _sourceColor(LogSource s) {
    final t = context.lokal;
    switch (s) {
      case LogSource.dart:
        return t.muted;
      case LogSource.rust:
        return const Color(0xFF57B8FF);
      case LogSource.crash:
        return t.red;
      case LogSource.zone:
        return t.orange;
      case LogSource.platform:
        return t.purple;
    }
  }

  Future<void> _copyAll(List<LogEntry> entries) async {
    if (entries.isEmpty) return;
    await Clipboard.setData(
      ClipboardData(text: entries.map(_format).join('\n')),
    );
    if (!mounted) return;
    LokalToast.fromSnackBar(context, SnackBar(content: Text(l10n.logsCopied)));
  }

  Future<void> _shareAll(List<LogEntry> entries) async {
    if (entries.isEmpty) return;
    try {
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final directory = await getTemporaryDirectory();
      final file = File(p.join(directory.path, 'lokal_logs_$stamp.txt'));
      await file.writeAsString(entries.map(_format).join('\n'), flush: true);
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: _subject),
      );
    } catch (e) {
      _snack(l10n.shareFailed(e));
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    LokalToast.fromSnackBar(context, SnackBar(content: Text(message)));
  }

  // ponytail: unlisted dpaste paste, anonymous, 30-day expiry. Not private —
  // anyone with the link reads it — so we warn + consent before upload instead
  // of building a lossy scrubber that would strip diagnostic file paths.
  Future<void> _uploadAsLink(List<LogEntry> entries) async {
    if (entries.isEmpty) return;
    final ok = await showLokalConfirmSheet(
      context: context,
      title: l10n.uploadLogsAsALink,
      message: l10n.yourLogsAreUploadedToDpaste,
      confirmLabel: l10n.upload,
    );
    if (!ok) return;

    setState(() => _isUploading = true);
    try {
      final res = await http
          .post(
            Uri.parse('https://dpaste.com/api/v2/'),
            headers: {'User-Agent': 'Lokal/$kAppVersionLabel'},
            body: {
              'content': entries.map(_format).join('\n'),
              'syntax': 'text',
              'expiry_days': '30',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode == 201) {
        final url = res.body.trim();
        await Clipboard.setData(ClipboardData(text: url));
        if (!mounted) return;
        _showLinkDialog(url);
      } else {
        _snack(l10n.uploadFailed(res.statusCode));
      }
    } catch (e) {
      _snack(l10n.uploadFailed2(e));
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  void _showLinkDialog(String url) {
    showLokalSettingsSheet<void>(
      context: context,
      builder: (ctx) => LokalSheetBody(
        title: l10n.linkReady,
        children: [
          LokalSettingsCard(
            color: ctx.lokal.surface2,
            padding: const EdgeInsets.all(14),
            child: SelectableText(
              url,
              style: LokalTheme.label(
                ctx.lokal,
                size: 12.5,
                color: ctx.lokal.accent,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: LokalSettingsActionButton(
                  label: l10n.copy,
                  primary: false,
                  expand: true,
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: url));
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: LokalSettingsActionButton(
                  label: l10n.share,
                  expand: true,
                  onPressed: () {
                    Navigator.pop(ctx);
                    SharePlus.instance.share(
                      ShareParams(text: url, subject: _subject),
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _saveAsText(List<LogEntry> entries) async {
    if (entries.isEmpty) return;
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final fileName = 'lokal_logs_$stamp.txt';
    final bytes = Uint8List.fromList(
      utf8.encode(entries.map(_format).join('\n')),
    );
    final savedUri = await FilePicker.saveFile(
      dialogTitle: l10n.saveLogs,
      fileName: fileName,
      mimeType: 'text/plain',
      type: FileType.custom,
      allowedExtensions: const ['txt'],
      bytes: bytes,
    );
    if (savedUri == null || !mounted) return;
    final share = await showLokalConfirmSheet(
      context: context,
      title: l10n.saved,
      message: l10n.savedToNNNshareIt(savedUri.toString()),
      confirmLabel: l10n.share,
      cancelLabel: l10n.no,
    );
    if (share && mounted) {
      // Android's SAF save picker may return "/document/primary:Music/..."
      // with NO URI scheme. That is a document identifier, not a readable
      // filesystem path. Re-share the exported bytes in every case instead
      // of guessing whether XFile can access the returned path.
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(bytes, mimeType: 'text/plain'),
          ],
          fileNameOverrides: [fileName],
          subject: _subject,
        ),
      );
    }
  }

  Future<void> _confirmClear() async {
    final ok = await showLokalConfirmSheet(
      context: context,
      title: l10n.clearLogs,
      message: l10n.thisRemovesAllEntriesFromMemory(
        AppLog.instance.entries.length,
      ),
      confirmLabel: l10n.clear,
      destructive: true,
    );
    if (ok) {
      AppLog.instance.clear();
    }
  }

  /// More: upload as a link, save as text, clear.
  Future<void> _more() async {
    final entries = _filtered(AppLog.instance.entries);
    final empty = AppLog.instance.entries.isEmpty;
    final picked = await showLokalSettingsSheet<String>(
      context: context,
      title: l10n.logs,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!empty && !_isUploading)
            LokalSheetOption(
              label: l10n.copyLink,
              description: 'Upload to dpaste and copy the link',
              icon: Icons.link_rounded,
              onTap: () => Navigator.pop(ctx, 'link'),
            ),
          if (!empty)
            LokalSheetOption(
              label: l10n.saveAsText,
              icon: Icons.save_alt_rounded,
              onTap: () => Navigator.pop(ctx, 'save'),
            ),
          LokalSheetOption(
            label: l10n.clear,
            icon: Icons.delete_outline_rounded,
            onTap: () => Navigator.pop(ctx, 'clear'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (picked) {
      case 'link':
        await _uploadAsLink(entries);
      case 'save':
        await _saveAsText(entries);
      case 'clear':
        await _confirmClear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return DisplayModeWrapper(
      child: Scaffold(
        backgroundColor: t.bg,
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListenableBuilder(
                listenable: AppLog.instance,
                builder: (context, _) {
                  final count = AppLog.instance.entries.length;
                  return LokalSettingsHeader(
                    title: l10n.logs,
                    subtitle: count == 0 ? null : '$count entries',
                    actions: [
                      LokalSettingsHeaderAction(
                        icon: Icons.copy_rounded,
                        tooltip: l10n.copy,
                        onPressed: count == 0
                            ? null
                            : () =>
                                  _copyAll(_filtered(AppLog.instance.entries)),
                      ),
                      LokalSettingsHeaderAction(
                        icon: Icons.ios_share_rounded,
                        tooltip: l10n.share,
                        onPressed: count == 0
                            ? null
                            : () =>
                                  _shareAll(_filtered(AppLog.instance.entries)),
                      ),
                      LokalSettingsHeaderAction(
                        icon: Icons.more_horiz_rounded,
                        tooltip: l10n.more,
                        onPressed: _more,
                      ),
                    ],
                  );
                },
              ),
              if (_isUploading)
                LinearProgressIndicator(
                  minHeight: 2,
                  color: t.accent,
                  backgroundColor: t.surface3,
                ),
              _buildControls(context),
              Expanded(child: _buildList(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _searchCtrl,
            style: TextStyle(color: context.lokal.text, fontSize: 13.5),
            decoration: lokalInputDecoration(
              context,
              hint: l10n.filterLogs,
              prefixIcon: Icon(
                Icons.search_rounded,
                size: 18,
                color: context.lokal.muted,
              ),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _chip(context, null, l10n.all),
                for (final s in LogSource.values) _chip(context, s, s.name),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, LogSource? source, String label) {
    final t = context.lokal;
    final selected = source == null
        ? _sources.isEmpty
        : _sources.contains(source);
    final color = source == null ? t.accent : _sourceColor(source);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Semantics(
        button: true,
        selected: selected,
        child: GestureDetector(
          onTap: () {
            AppHaptics.tap();
            setState(() {
              if (source == null) {
                _sources.clear();
              } else if (_sources.contains(source)) {
                _sources.remove(source);
              } else {
                _sources.add(source);
              }
            });
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: selected ? color.withValues(alpha: 0.15) : t.surface2,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: selected ? color.withValues(alpha: .6) : t.border,
              ),
            ),
            child: Text(
              label.toUpperCase(),
              style: LokalTheme.label(
                t,
                size: 10.5,
                color: selected ? color : t.muted,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    final t = context.lokal;
    return ListenableBuilder(
      listenable: AppLog.instance,
      builder: (context, _) {
        final entries = _filtered(AppLog.instance.entries);
        _stickIfWanted();
        if (entries.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                AppLog.instance.entries.isEmpty
                    ? l10n.noLogsYet
                    : l10n.noMatches,
                style: TextStyle(color: t.muted),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return Container(
          margin: EdgeInsets.fromLTRB(
            16,
            4,
            16,
            16 + MediaQuery.paddingOf(context).bottom,
          ),
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: t.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (!_ctrl.hasClients) return false;
              final max = _ctrl.position.maxScrollExtent;
              final cur = _ctrl.position.pixels;
              final atBottom = (max - cur).abs() < 64;
              if (atBottom != _stickToBottom) {
                setState(() => _stickToBottom = atBottom);
              }
              return false;
            },
            child: ListView.builder(
              controller: _ctrl,
              padding: const EdgeInsets.all(12),
              itemCount: entries.length,
              itemBuilder: (context, i) {
                final e = entries[i];
                final c = _sourceColor(e.source);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: RichText(
                    text: TextSpan(
                      style: TextStyle(
                        fontFamily: LokalTheme.mono,
                        fontFamilyFallback: AppTheme.fontFamilyFallback,
                        fontSize: 11,
                        height: 1.35,
                        color: t.text,
                      ),
                      children: [
                        TextSpan(
                          text: '${_ts(e.timestamp)} ',
                          style: TextStyle(color: t.muted),
                        ),
                        TextSpan(
                          text: '[${e.source.name}] ',
                          style: TextStyle(
                            color: c,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        TextSpan(text: e.message),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
