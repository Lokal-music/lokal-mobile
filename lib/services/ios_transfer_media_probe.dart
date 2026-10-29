import 'dart:async';
import 'dart:convert';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_session.dart';
import 'package:ffmpeg_kit_flutter_new_audio/log_redirection_strategy.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

import '../models/ios_transfer_import.dart';
import 'ios_transfer_media.dart';

export 'ios_transfer_media.dart'
    show IosTransferMediaFailure, IosTransferMediaException;

/// Local bundled native reader for an active writer's native-derived staging
/// path. It never opens a URL, persists a path, changes global logs, or cancels
/// unrelated playback/transcoding. Product import remains capability-disabled.
class IosTransferMediaProbe {
  const IosTransferMediaProbe();

  Future<IosTransferMediaInfo> inspect(
    IosTransferImportLease lease, {
    required bool Function() isCurrent,
    required Future<void> Function() validateOwnership,
    Future<void>? cancelled,
  }) async {
    if (lease.reconcileOnly ||
        lease.sourcePath == null ||
        lease.job.receivedBytes == null) {
      throw const IosTransferMediaException(IosTransferMediaFailure.invalid);
    }
    final completed = Completer<FFprobeSession>();
    FFprobeSession? session;
    var retired = false;
    void checkCurrent() {
      if (retired || !isCurrent()) {
        throw const IosTransferMediaException(IosTransferMediaFailure.retired);
      }
    }

    Future<void> validateCurrent() async {
      checkCurrent();
      try {
        await validateOwnership();
      } catch (_) {
        // Lost writer authority is not evidence that downloaded media is bad.
        throw const IosTransferMediaException(IosTransferMediaFailure.retired);
      }
      checkCurrent();
    }

    Future<void> cancelOwned() async {
      final id = session?.getSessionId();
      // Both plugin cancellation APIs allow null to mean "cancel everything".
      // Never enter either API without our own positive native session ID.
      if (id == null || id < 1) return;
      try {
        await FFmpegKit.cancel(id).timeout(const Duration(seconds: 2));
      } catch (_) {
        // Results are already retired. No cancelled probe can authorize import.
      }
    }

    Future<IosTransferMediaInfo> run() async {
      await validateCurrent();
      session = await FFprobeSession.create(
        IosTransferMedia.arguments(lease.sourcePath!),
        (finished) {
          if (!completed.isCompleted) completed.complete(finished);
        },
        (_) {},
        LogRedirectionStrategy.neverPrintLogs,
      );
      checkCurrent();
      final id = session!.getSessionId();
      if (id == null || id < 1) {
        throw const IosTransferMediaException(
          IosTransferMediaFailure.unavailable,
        );
      }
      await FFmpegKitConfig.asyncFFprobeExecute(session!);
      if (retired) {
        await cancelOwned();
        checkCurrent();
      }
      final finished = await completed.future;
      checkCurrent();
      final code = await finished.getReturnCode();
      if (code == null) {
        throw const IosTransferMediaException(
          IosTransferMediaFailure.unavailable,
        );
      }
      if (!ReturnCode.isSuccess(code)) {
        throw const IosTransferMediaException(IosTransferMediaFailure.invalid);
      }
      final output = await finished.getAllLogsAsString(2000);
      checkCurrent();
      if (output == null) {
        throw const IosTransferMediaException(
          IosTransferMediaFailure.unavailable,
        );
      }
      try {
        jsonDecode(output);
      } on FormatException {
        // A successful quiet FFprobe must produce complete JSON. A truncated
        // plugin reply is a reader failure, not proof of a bad download.
        throw const IosTransferMediaException(
          IosTransferMediaFailure.unavailable,
        );
      }
      final result = IosTransferMedia.parse(
        output,
        expectedBytes: lease.job.receivedBytes!,
      );
      await validateCurrent();
      return result;
    }

    try {
      return await Future.any([
        run(),
        if (cancelled != null)
          cancelled.then<IosTransferMediaInfo>(
            (_) => throw const IosTransferMediaException(
              IosTransferMediaFailure.retired,
            ),
          ),
      ]).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const IosTransferMediaException(IosTransferMediaFailure.timeout);
    } on IosTransferMediaException {
      rethrow;
    } on FormatException {
      throw const IosTransferMediaException(IosTransferMediaFailure.invalid);
    } catch (_) {
      // JSON/plugin/native errors must not expose private paths or media tags.
      throw const IosTransferMediaException(
        IosTransferMediaFailure.unavailable,
      );
    } finally {
      retired = true;
      if (!completed.isCompleted) await cancelOwned();
    }
  }
}
