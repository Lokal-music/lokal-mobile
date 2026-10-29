import 'package:flutter/material.dart';

import 'dart:io';

/// Lokal's main settings groups, followed by shortcut-only subpages.
///
/// Desktop's Integrations and Add-ons are one flow here: [integrations] is
/// Online sources, and [addons] opens it at its add-ons.
enum LokalSettingsGroup {
  integrations(
    'Online sources',
    'Playback sources, add-ons, servers and radio',
    Icons.cloud_rounded,
  ),
  playback(
    'Playback',
    'ReplayGain, crossfade, queue, equalizer and lyrics',
    Icons.play_circle_outline_rounded,
  ),
  output(
    'Advanced output',
    'USB DAC, bit-perfect, engine, Bluetooth and volume',
    Icons.usb_rounded,
  ),
  library(
    'Library',
    'Folders, scanning and library maintenance',
    Icons.library_music_rounded,
  ),
  appearance(
    'Appearance',
    'Theme, accent, text size, Now Playing and interface',
    Icons.palette_rounded,
  ),
  data(
    'Data',
    'Accounts, Desktop link, caches and clearing your library',
    Icons.storage_rounded,
  ),
  about(
    'About',
    'Version, what’s new, licences and logs',
    Icons.info_outline_rounded,
  ),

  /// Home's appearance shortcut exposes only theme and accent.
  themeAccent(
    'Theme & accent',
    'Choose your theme and accent color',
    Icons.palette_rounded,
    parent: LokalSettingsGroup.appearance,
  ),

  /// SpotiFLAC add-ons: Online sources, scrolled to its add-ons.
  addons(
    'Add-ons',
    'SpotiFLAC add-ons for songs that aren’t in your library',
    Icons.extension_rounded,
    parent: LokalSettingsGroup.integrations,
  );

  const LokalSettingsGroup(
    this._label,
    this._description,
    this._icon, {
    this.parent,
  });

  final String _label;
  final String _description;
  final IconData _icon;

  String get label =>
      this == output && Platform.isIOS ? 'Audio output' : _label;
  String get description => this == output && Platform.isIOS
      ? 'AirPlay, Bluetooth, volume and crossfeed'
      : _description;
  IconData get icon =>
      this == output && Platform.isIOS ? Icons.headphones_rounded : _icon;

  /// The group this page opens from; `null` for the listed groups.
  final LokalSettingsGroup? parent;

  /// The groups shown on the Settings root, with Advanced output after Playback.
  static List<LokalSettingsGroup> get listed => [
    for (final group in values)
      if (group.parent == null && group != about) group,
  ];
}

/// The sections of Online sources, by the title deep links use.
abstract final class LokalOnlineSections {
  static const streaming = 'Streaming & search';
  static const addons = 'Add-ons';
  static const repositories = 'Add-on repositories';
  static const accounts = 'Accounts & scrobbling';
  static const radioVideos = 'Radio & videos';

  /// Section names older links used, mapped to where they are now.
  static const aliases = {
    'accounts': accounts,
    'scrobbling': accounts,
    'network sources': streaming,
    'repositories': repositories,
    'radio': radioVideos,
    'videos': radioVideos,
  };
}

/// Account connections now share Data with desktop pairing and stored data.
abstract final class LokalDataSections {
  static const accounts = 'Accounts';
  static const accountAliases = {
    'accounts',
    'accounts & scrobbling',
    'scrobbling',
    'desktop link',
    'youtube music',
    'spotify',
    'discord rich presence',
  };
}
