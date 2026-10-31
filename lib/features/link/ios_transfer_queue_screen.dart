import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/lokal_tokens.dart';
import '../../l10n/l10n.dart';
import '../../models/ios_transfer_models.dart';
import '../../providers/ios_transfer_provider.dart';
import '../../services/ios_transfer_queue.dart';
import '../../services/ios_transfer_session.dart';
import '../../widgets/lokal/settings/lokal_settings_kit.dart';

/// Hidden until the native replacement engine is qualified and enabled.
class IosTransferQueueEntry extends ConsumerStatefulWidget {
  const IosTransferQueueEntry({super.key});
  @override
  ConsumerState<IosTransferQueueEntry> createState() => _EntryState();
}

class _EntryState extends ConsumerState<IosTransferQueueEntry> {
  bool _available = false;
  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    final session = ref.read(iosTransferSessionProvider);
    if (session == null) return;
    try {
      final capability = await session.native.capability();
      if (mounted) {
        setState(
          () => _available =
              session.active &&
              capability.canCopyToLibrary &&
              capability.upload,
        );
      }
    } catch (_) {
      /* Foreground copies remain the available product path. */
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_available) return const SizedBox.shrink();
    return LokalSettingsBlock(
      child: LokalSettingsCard(
        child: ListTile(
          leading: Icon(Icons.swap_vert_rounded, color: context.lokal.accent),
          title: Text(lokalText('File transfers')),
          subtitle: Text(lokalText('Progress, recovery and completed copies')),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () {
            final session = ref.read(iosTransferSessionProvider);
            if (session == null || !session.active) return;
            unawaited(showIosTransferQueue(context, session));
          },
        ),
      ),
    );
  }
}

Future<void> showIosTransferQueue(
  BuildContext context,
  IosTransferSession session,
) {
  final controller = IosTransferQueueController(
    native: session.native,
    ensureReady: session.start,
    recoverSession: session.foreground,
    prepareUpload: (job) async {
      final id = int.tryParse(job.intent.identity.localSongId ?? '');
      if (id == null || id <= 0) {
        throw StateError('The original library song is unavailable.');
      }
      await session.enqueueUploadSong(
        songId: id,
        frozenIntent: job.intent,
        expectedPairing: IosTransferPairing(
          scope: job.intent.identity.scope,
          desktopUserId: job.intent.identity.desktopUserId,
        ),
        prepared: (_) {},
      );
    },
  );
  final duration = MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 250);
  return Navigator.of(context).push<void>(
    PageRouteBuilder(
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      pageBuilder: (_, _, _) => IosTransferQueueScreen(controller: controller),
      transitionsBuilder: (_, animation, _, child) => FadeTransition(
        opacity: animation.drive(CurveTween(curve: Curves.easeInOutCubic)),
        child: child,
      ),
    ),
  );
}

class IosTransferQueueScreen extends StatefulWidget {
  const IosTransferQueueScreen({super.key, required this.controller});
  final IosTransferQueueController controller;
  @override
  State<IosTransferQueueScreen> createState() => _QueueState();
}

class _QueueState extends State<IosTransferQueueScreen> {
  IosTransferQueueController get queue => widget.controller;
  @override
  void initState() {
    super.initState();
    queue.addListener(_changed);
    unawaited(queue.start());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    queue.removeListener(_changed);
    queue.dispose();
    super.dispose();
  }

  Future<void> _act(IosTransferJob job, IosTransferQueueAction action) async {
    if (action == IosTransferQueueAction.cancel) {
      final confirmed = await showLokalConfirmSheet(
        context: context,
        title: lokalText('Cancel this transfer?'),
        message: lokalText(
          'Original songs stay on both devices. If the desktop already received this upload, its copy is kept.',
        ),
        confirmLabel: lokalText('Cancel transfer'),
      );
      if (!mounted || !confirmed) return;
    }
    await queue.act(job, action);
  }

  String _phase(IosTransferJob job) => lokalText(switch (job.phase) {
    IosTransferPhase.queued => 'Queued',
    IosTransferPhase.waiting => 'Waiting to prepare file',
    IosTransferPhase.transferring =>
      job.direction == 'upload' ? 'Sending to desktop' : 'Receiving on iPhone',
    IosTransferPhase.received ||
    IosTransferPhase.downloaded ||
    IosTransferPhase.staged => 'Verifying file',
    IosTransferPhase.validating ||
    IosTransferPhase.importing => 'Adding to library',
    IosTransferPhase.complete => 'Complete',
    IosTransferPhase.interrupted => 'Interrupted',
    IosTransferPhase.cancelled => 'Cancelled',
    IosTransferPhase.failed => 'Needs attention',
  });
  String _action(IosTransferQueueAction action) => lokalText(switch (action) {
    IosTransferQueueAction.cancel => 'Cancel transfer',
    IosTransferQueueAction.retryDownload => 'Retry download',
    IosTransferQueueAction.prepareUpload => 'Resume preparation',
    IosTransferQueueAction.matchUpload => 'Check desktop receipt',
    IosTransferQueueAction.cleanupUpload => 'Free temporary copy',
  });
  String? get _notice => switch (queue.notice) {
    IosTransferQueueNotice.none => null,
    IosTransferQueueNotice.unavailable => 'Background transfers are not available. Use foreground copying with both apps open.',
    IosTransferQueueNotice.refreshFailed =>
      'Could not read transfer status. Refresh to try again.',
    IosTransferQueueNotice.changed =>
      'Transfers changed while loading. Refresh for current status.',
    IosTransferQueueNotice.actionFailed => 'The action could not finish. Refresh and check the connection and available storage before trying again.',
    IosTransferQueueNotice.noMatch => 'The desktop has not confirmed this file. The upload remains paused; no audio was resent.',
    IosTransferQueueNotice.cleanupPending => 'The transfer is settled. Its temporary copy will stay until file activity has stopped. You can free it later.',
  };

  Widget _row(IosTransferJob job) {
    final t = context.lokal;
    final progress = queue.summary?.progress
        .where((entry) => entry.id == job.id && entry.revision == job.revision)
        .firstOrNull;
    final expected = progress?.expectedBytes ?? job.intent.expectedBytes;
    final fraction = progress != null && expected != null
        ? (progress.bytes / expected).clamp(0.0, 1.0)
        : null;
    final uncertain =
        job.direction == 'upload' &&
        {
          IosTransferPhase.interrupted,
          IosTransferPhase.failed,
        }.contains(job.phase);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: LokalSettingsCard(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  job.direction == 'upload'
                      ? Icons.upload_rounded
                      : Icons.download_rounded,
                  color: t.accent,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        job.intent.metadata.title,
                        style: TextStyle(
                          color: t.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        job.intent.metadata.artist,
                        style: TextStyle(color: t.muted),
                      ),
                      Text(_phase(job), style: TextStyle(color: t.muted)),
                    ],
                  ),
                ),
              ],
            ),
            if (job.phase == IosTransferPhase.transferring) ...[
              const SizedBox(height: 12),
              Semantics(
                label: _phase(job),
                value: fraction == null ? null : '${(fraction * 100).floor()}%',
                child: LinearProgressIndicator(value: fraction),
              ),
              if (progress?.waitingForConnectivity == true)
                Text(
                  lokalText('Waiting for Wi-Fi'),
                  style: TextStyle(color: t.muted),
                ),
            ],
            if (uncertain)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  lokalText(
                    'Check whether the desktop received this recording before taking further action. Audio will not be resent automatically.',
                  ),
                  style: TextStyle(color: t.muted),
                ),
              ),
            if (job.direction == 'upload' &&
                {
                  IosTransferPhase.complete,
                  IosTransferPhase.cancelled,
                }.contains(job.phase))
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  lokalText(
                    'Freeing the temporary copy keeps your original song and the desktop copy.',
                  ),
                  style: TextStyle(color: t.muted),
                ),
              ),
            Wrap(
              spacing: 8,
              children: [
                for (final action in queue.actions(job))
                  TextButton(
                    onPressed: queue.canActOn(job, action)
                        ? () => _act(job, action)
                        : null,
                    child: Text(_action(action)),
                  ),
              ],
            ),
            if (queue.acting == job.id) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        title: Text(lokalText('File transfers')),
        backgroundColor: t.bg,
        foregroundColor: t.text,
        actions: [
          IconButton(
            tooltip: lokalText('Refresh'),
            onPressed: queue.loading ? null : queue.reload,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: queue.reload,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        lokalText(
                          'Original files stay on their source device.',
                        ),
                        style: TextStyle(color: t.muted),
                      ),
                      if (_notice case final message?)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              lokalText(message),
                              style: TextStyle(color: t.text),
                            ),
                          ),
                        ),
                      if (queue.summary?.persistenceFailed == true)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                lokalText(
                                  'Transfer storage needs recovery. Actions are paused to protect your files.',
                                ),
                                style: TextStyle(color: t.text),
                              ),
                              TextButton(
                                onPressed: queue.canRecover
                                    ? queue.recoverStorage
                                    : null,
                                child: Text(lokalText('Recover transfers')),
                              ),
                            ],
                          ),
                        ),
                      if (queue.summary?.pauses.isNotEmpty == true)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            lokalText(
                              'Some transfers are paused. Reconnect to the paired desktop and refresh.',
                            ),
                            style: TextStyle(color: t.muted),
                          ),
                        ),
                      if (queue.loading || {'recovery', 'connection'}.contains(queue.acting))
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: LinearProgressIndicator(),
                        ),
                      if (queue.available &&
                          !queue.loading &&
                          queue.jobs.isEmpty &&
                          !queue.stale)
                        Padding(
                          padding: const EdgeInsets.only(top: 24),
                          child: Text(
                            lokalText('No file transfers yet.'),
                            style: TextStyle(color: t.text),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              for (final pause in queue.summary?.pauses ?? <IosTransferPause>[])
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: LokalSettingsCard(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            lokalText(
                              pause.reason == 'pairingChanged'
                                  ? 'This desktop pairing was retired. Pair again to create new transfers.'
                                  : 'This connection is paused. Resume after checking the paired desktop.',
                            ),
                            style: TextStyle(color: t.text),
                          ),
                          if (pause.reason != 'pairingChanged')
                            TextButton(
                              onPressed: queue.canAct
                                  ? () => queue.resumePause(pause)
                                  : null,
                              child: Text(lokalText('Resume connection')),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              SliverList.builder(
                itemCount: queue.jobs.length,
                itemBuilder: (_, index) => _row(queue.jobs[index]),
              ),
              if (queue.hasMore)
                SliverToBoxAdapter(
                  child: Center(
                    child: TextButton(
                      onPressed: queue.loading ? null : queue.loadMore,
                      child: Text(lokalText('Show more transfers')),
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 32)),
            ],
          ),
        ),
      ),
    );
  }
}
