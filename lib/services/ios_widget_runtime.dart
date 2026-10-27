import 'package:flutter/foundation.dart';

import '../providers/player_provider.dart';
import 'album_art_service.dart';
import 'ios_widget_method_channel_transport.dart';
import 'ios_widget_owned_artwork.dart';
import 'ios_widget_publication_coordinator.dart';
import 'ios_widget_state_sampler.dart';

/// Host metadata owner only. Missing profile capability prevents artwork work.
/// Native publication is optional and cannot create or control an audio owner.
class IosWidgetRuntime {
  IosWidgetRuntime({
    required int accentArgb,
    required this.coordinator,
    required this.artwork,
    this.materializedArtwork,
    DateTime Function()? clock,
  }) {
    sampler = IosWidgetStateSampler(
      accentArgb: accentArgb,
      clock: clock,
      onSample: (sample) => coordinator.submit(
        sample.metadata,
        loadArtwork: sample.loadArtwork
            ? () => artwork.load(sample.artworkSources)
            : null,
        reloadTimelines: sample.reloadTimelines,
      ),
    );
    materializedArtwork?.addListener(_artworkChanged);
  }

  factory IosWidgetRuntime.system({required int accentArgb}) =>
      IosWidgetRuntime(
        accentArgb: accentArgb,
        coordinator: IosWidgetPublicationCoordinator(
          transport: IosWidgetMethodChannelTransport(),
        ),
        artwork: IosWidgetOwnedArtworkLoader.system(),
        materializedArtwork: AlbumArtService.instance.materializedArtwork,
      );

  final IosWidgetPublicationCoordinator coordinator;
  final IosWidgetOwnedArtworkLoader artwork;
  final ValueListenable<({String source, String path})?>? materializedArtwork;
  late final IosWidgetStateSampler sampler;
  bool _disposed = false;

  void observe(PlayerState state) => sampler.observe(state);
  void setAccent(int value) => sampler.setAccent(value);

  void _artworkChanged() {
    final change = materializedArtwork?.value;
    if (!_disposed && change != null) {
      sampler.artworkMaterialized(change.source);
    }
  }

  Future<void> flush() => coordinator.flush();

  Future<void> retry() async {
    if (_disposed) return;
    sampler.republishLatest();
    await coordinator.retry();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    materializedArtwork?.removeListener(_artworkChanged);
    sampler.dispose();
    coordinator.dispose();
  }
}
