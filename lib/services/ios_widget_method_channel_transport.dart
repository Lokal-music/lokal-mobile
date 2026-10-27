import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/ios_widget_snapshot.dart';
import 'ios_widget_publication_coordinator.dart';

/// Native metadata transport only. No HomeWidget Android API, source URL,
/// caller-supplied group identifier, player or credentials cross this channel.
class IosWidgetMethodChannelTransport implements IosWidgetPublicationTransport {
  IosWidgetMethodChannelTransport({
    this.channel = const MethodChannel('lokal/widgets'),
    bool? supported,
  }) : supported = supported ?? Platform.isIOS;

  final MethodChannel channel;
  final bool supported;

  @override
  Future<IosWidgetPublicationCapability> capability() async {
    if (!supported) {
      return const IosWidgetPublicationCapability(
        available: false,
        unavailableReason: IosWidgetUnavailableReason.unsupportedPlatform,
      );
    }
    final raw = await channel.invokeMethod<Object?>('capability');
    if (raw is! Map || raw['available'] is! bool) {
      throw const FormatException('Invalid widget capability');
    }
    if (raw['available'] != true) {
      final reason = IosWidgetUnavailableReason.values
          .where((value) => value.name == raw['reason'])
          .firstOrNull;
      return IosWidgetPublicationCapability(
        available: false,
        unavailableReason: reason ?? IosWidgetUnavailableReason.unknown,
      );
    }
    return IosWidgetPublicationCapability(
      available: true,
      committedRevision: _revision(raw['committedRevision'], allowZero: true),
    );
  }

  @override
  Future<IosWidgetPublicationReceipt> publish(
    IosWidgetSnapshot metadata,
    Map<String, Uint8List> artworkByAlias, {
    required bool reloadTimelines,
  }) async {
    if (!supported) {
      throw UnsupportedError('iPhone widget transport unavailable');
    }
    final document = Uint8List.fromList(utf8.encode(metadata.encode()));
    if (document.length > IosWidgetSnapshot.maximumBytes ||
        artworkByAlias.length > 13) {
      throw const FormatException('Widget publication exceeds its byte budget');
    }
    final fields = metadata.toJson();
    final aliases = <String>{
      if (fields['current'] case final Map current) current['id'] as String,
      for (final row in fields['recommendations']! as List)
        (row as Map)['id'] as String,
    };
    if (artworkByAlias.keys.any((key) => !aliases.contains(key))) {
      throw const FormatException('Unreferenced widget artwork');
    }
    var bytes = 0;
    for (final image in artworkByAlias.values) {
      if (image.length >
          IosWidgetPublicationCoordinator.maximumArtworkBytes - bytes) {
        throw const FormatException('Widget artwork exceeds its byte budget');
      }
      bytes += image.length;
    }
    final raw = await channel.invokeMethod<Object?>('publish', {
      'metadata': document,
      'artwork': artworkByAlias,
      'reloadTimelines': reloadTimelines,
    });
    if (raw is! Map ||
        raw['artworkByAlias'] is! Map ||
        raw['artworkDegraded'] is! bool ||
        (raw['lastArtwork'] != null && raw['lastArtwork'] is! String)) {
      throw const FormatException('Invalid widget publication acknowledgement');
    }
    final names = <String, String>{};
    for (final entry in (raw['artworkByAlias']! as Map).entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const FormatException('Invalid widget artwork acknowledgement');
      }
      names[entry.key as String] = entry.value as String;
    }
    return IosWidgetPublicationReceipt(
      revision: _revision(raw['revision']),
      artworkByAlias: names,
      lastArtwork: raw['lastArtwork'] as String?,
      artworkDegraded: raw['artworkDegraded']! as bool,
    );
  }

  static int _revision(Object? raw, {bool allowZero = false}) {
    if (raw is! int ||
        raw < (allowZero ? 0 : 1) ||
        raw > IosWidgetPublicationCoordinator.maximumRevision) {
      throw const FormatException('Invalid native widget revision');
    }
    return raw;
  }
}
