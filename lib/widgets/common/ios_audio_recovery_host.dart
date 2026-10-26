import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flick/services/casting/casting_service.dart';
import 'package:flick/services/ios_local_audio_requests.dart';

import 'audio_recovery_notice.dart';

class IosAudioRecoveryHost extends StatelessWidget {
  const IosAudioRecoveryHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) return child;
    return ValueListenableBuilder(
      valueListenable: CastingService.instance.isActiveNotifier,
      builder: (context, remote, _) {
        final media = MediaQuery.of(context);
        return LayoutBuilder(
          builder: (context, host) => Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, content) {
                    final height = host.maxHeight - content.maxHeight;
                    double remaining(double inset) =>
                        math.max(0, inset - height);
                    return MediaQuery(
                      data: media.copyWith(
                        size: content.biggest,
                        padding: media.padding.copyWith(
                          bottom: remaining(media.padding.bottom),
                        ),
                        viewPadding: media.viewPadding.copyWith(
                          bottom: remaining(media.viewPadding.bottom),
                        ),
                        viewInsets: media.viewInsets.copyWith(
                          bottom: remaining(media.viewInsets.bottom),
                        ),
                      ),
                      child: child,
                    );
                  },
                ),
              ),
              AudioRecoveryNotice(
                phase: IosLocalAudioRequests.lifecycle.phase,
                remoteOutputActive: remote,
              ),
            ],
          ),
        );
      },
    );
  }
}
