import 'package:flick/core/theme/app_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/services/app_preferences_service.dart'
    show AppPreferences;
import 'package:flick/providers/providers.dart';
import 'package:flick/services/widget_sync_service.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';

/// Home screen widgets: one tab per widget size, each with its background,
/// content, text size (with a preview) and accent.
class WidgetSettingsScreen extends ConsumerStatefulWidget {
  const WidgetSettingsScreen({super.key});

  @override
  ConsumerState<WidgetSettingsScreen> createState() =>
      _WidgetSettingsScreenState();
}

class _WidgetSettingsScreenState extends ConsumerState<WidgetSettingsScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(appPreferencesProvider);
    final tab = _tabs[_tab];
    return LokalSettingsScaffold(
      title: l10n.widgets,
      subtitle: 'Now Playing, Flow / Radio and Cover Flow. All widgets resize on your Android home screen; these controls customize the existing Now Playing layouts.',
      children: [
        LokalSettingsBlock(
          top: 16,
          child: LokalSegmented<int>(
            expand: true,
            value: _tab,
            segments: [
              for (final (i, tab) in _tabs.indexed)
                LokalSegment(i, tab.label()),
            ],
            onChanged: (i) => setState(() => _tab = i),
          ),
        ),
        ..._sections(context, tab, prefs),
      ],
    );
  }

  /// Saves [next] and sends it to the widgets on the home screen.
  void _push(AppPreferences next) =>
      WidgetSyncService.instance.pushCustomization(next);

  List<Widget> _sections(
    BuildContext context,
    _WidgetTab tab,
    AppPreferences prefs,
  ) {
    final notifier = ref.read(appPreferencesProvider.notifier);
    final scale = tab.textScale(prefs);
    void setScale(double v) {
      tab.setTextScale(notifier, v);
      _push(tab.withTextScale(ref.read(appPreferencesProvider), v));
    }

    return [
      if (tab.opacity != null)
        LokalSettingsSection(
          title: l10n.background,
          children: [
            LokalSettingChoice<int>(
              label: l10n.background,
              description: 'How much of the home screen shows through.',
              value: tab.opacity!(prefs),
              options: [
                LokalSegment(0, l10n.transparent),
                LokalSegment(1, l10n.light),
                LokalSegment(2, l10n.medium),
                LokalSegment(3, l10n.dark),
                LokalSegment(4, l10n.solid),
              ],
              onChanged: (v) {
                tab.setOpacity!(notifier, v);
                _push(tab.withOpacity!(ref.read(appPreferencesProvider), v));
              },
            ),
          ],
        ),
      LokalSettingsSection(
        title: l10n.content,
        children: [
          for (final toggle in tab.toggles)
            LokalSettingRow.toggle(
              label: toggle.label(),
              description: toggle.description(),
              value: toggle.value(prefs),
              onChanged: (v) {
                toggle.set(notifier, v);
                _push(toggle.copy(prefs, v));
              },
            ),
        ],
      ),
      LokalSettingsSection(
        title: l10n.textSize2,
        children: [
          LokalSettingSlider(
            label: l10n.fontScale,
            description: l10n.scalesWithWidgetSizeAutomatically,
            value: scale,
            min: 0.8,
            max: 2.5,
            divisions: 34,
            valueLabel: (v) => '${(v * 100).round()}%',
            onChanged: setScale,
            onValueTap: () => _showManualScaleDialog(
              context,
              value: scale,
              min: 0.8,
              max: 2.5,
              onChanged: setScale,
            ),
          ),
          LokalSettingCustom(
            label: l10n.preview,
            child: _WidgetTextPreview(
              titleBaseSp: tab.preview.$1,
              artistBaseSp: tab.preview.$2,
              manualScale: scale,
              accentColor: _resolveAccentColor(tab.accent(prefs)),
              centered: tab.centered,
            ),
          ),
        ],
      ),
      LokalSettingsSection(
        title: l10n.accentColor,
        children: [
          LokalSettingCustom(
            label: l10n.accentColor,
            child: _AccentPicker(
              value: tab.accent(prefs),
              onChanged: (v) {
                tab.setAccent(notifier, v);
                _push(tab.withAccent(ref.read(appPreferencesProvider), v));
              },
            ),
          ),
        ],
      ),
    ];
  }
}

/// One switch of a widget's content.
class _WidgetToggle {
  const _WidgetToggle({
    required this.label,
    required this.description,
    required this.value,
    required this.set,
    required this.copy,
  });

  final String Function() label;
  final String Function() description;
  final bool Function(AppPreferences) value;
  final void Function(AppPreferencesNotifier, bool) set;
  final AppPreferences Function(AppPreferences, bool) copy;
}

/// What one widget size can change, and where each value is kept.
class _WidgetTab {
  const _WidgetTab({
    required this.label,
    required this.toggles,
    required this.textScale,
    required this.setTextScale,
    required this.withTextScale,
    required this.accent,
    required this.setAccent,
    required this.withAccent,
    required this.preview,
    required this.centered,
    this.opacity,
    this.setOpacity,
    this.withOpacity,
  });

  final String Function() label;
  final List<_WidgetToggle> toggles;
  final double Function(AppPreferences) textScale;
  final void Function(AppPreferencesNotifier, double) setTextScale;
  final AppPreferences Function(AppPreferences, double) withTextScale;
  final String Function(AppPreferences) accent;
  final void Function(AppPreferencesNotifier, String) setAccent;
  final AppPreferences Function(AppPreferences, String) withAccent;

  /// The title and artist sizes, in sp, at 100%.
  final (int, int) preview;
  final bool centered;
  final int Function(AppPreferences)? opacity;
  final void Function(AppPreferencesNotifier, int)? setOpacity;
  final AppPreferences Function(AppPreferences, int)? withOpacity;
}

final _tabs = <_WidgetTab>[
  _WidgetTab(
    label: () => l10n.miniPlayer,
    opacity: (p) => p.widgetBgOpacity,
    setOpacity: (n, v) => n.setWidgetBgOpacity(v),
    withOpacity: (p, v) => p.copyWith(widgetBgOpacity: v),
    toggles: [
      _WidgetToggle(
        label: () => l10n.albumArt,
        description: () => l10n.showAlbumArtworkOnTheMini,
        value: (p) => p.widgetShowAlbumArt,
        set: (n, v) => n.setWidgetShowAlbumArt(v),
        copy: (p, v) => p.copyWith(widgetShowAlbumArt: v),
      ),
      _WidgetToggle(
        label: () => l10n.artistName,
        description: () => l10n.showArtistBelowSongTitle,
        value: (p) => p.widgetShowArtist,
        set: (n, v) => n.setWidgetShowArtist(v),
        copy: (p, v) => p.copyWith(widgetShowArtist: v),
      ),
    ],
    textScale: (p) => p.widgetTextScale,
    setTextScale: (n, v) => n.setWidgetTextScale(v),
    withTextScale: (p, v) => p.copyWith(widgetTextScale: v),
    accent: (p) => p.widgetAccentColor,
    setAccent: (n, v) => n.setWidgetAccentColor(v),
    withAccent: (p, v) => p.copyWith(widgetAccentColor: v),
    preview: (13, 11),
    centered: false,
  ),
  _WidgetTab(
    label: () => '4×3 Flagship',
    toggles: [
      _WidgetToggle(
        label: () => l10n.artistName,
        description: () => l10n.showArtistBelowSongTitle,
        value: (p) => p.widgetFlagshipShowArtist,
        set: (n, v) => n.setWidgetFlagshipShowArtist(v),
        copy: (p, v) => p.copyWith(widgetFlagshipShowArtist: v),
      ),
    ],
    textScale: (p) => p.widgetFlagshipTextScale,
    setTextScale: (n, v) => n.setWidgetFlagshipTextScale(v),
    withTextScale: (p, v) => p.copyWith(widgetFlagshipTextScale: v),
    accent: (p) => p.widgetFlagshipAccent,
    setAccent: (n, v) => n.setWidgetFlagshipAccent(v),
    withAccent: (p, v) => p.copyWith(widgetFlagshipAccent: v),
    preview: (15, 12),
    centered: true,
  ),
  _WidgetTab(
    label: () => '2×2',
    opacity: (p) => p.widgetCompactBgOpacity,
    setOpacity: (n, v) => n.setWidgetCompactBgOpacity(v),
    withOpacity: (p, v) => p.copyWith(widgetCompactBgOpacity: v),
    toggles: [
      _WidgetToggle(
        label: () => l10n.albumArt,
        description: () => l10n.useAlbumArtAsBackground,
        value: (p) => p.widgetCompactShowAlbumArt,
        set: (n, v) => n.setWidgetCompactShowAlbumArt(v),
        copy: (p, v) => p.copyWith(widgetCompactShowAlbumArt: v),
      ),
      _WidgetToggle(
        label: () => l10n.artistName,
        description: () => l10n.showArtistBelowSongTitle,
        value: (p) => p.widgetCompactShowArtist,
        set: (n, v) => n.setWidgetCompactShowArtist(v),
        copy: (p, v) => p.copyWith(widgetCompactShowArtist: v),
      ),
    ],
    textScale: (p) => p.widgetCompactTextScale,
    setTextScale: (n, v) => n.setWidgetCompactTextScale(v),
    withTextScale: (p, v) => p.copyWith(widgetCompactTextScale: v),
    accent: (p) => p.widgetCompactAccent,
    setAccent: (n, v) => n.setWidgetCompactAccent(v),
    withAccent: (p, v) => p.copyWith(widgetCompactAccent: v),
    preview: (15, 12),
    centered: true,
  ),
];

/// The widget accents, as the home screen widgets draw them.
List<(String, String, Color)> _accents() => [
  ('theme', l10n.linkFollowAccent, AppColors.accent),
  ('white', l10n.white, Colors.white),
  ('amber', l10n.amber, const Color(0xFFFFB300)),
  ('blue', l10n.blue, const Color(0xFF64B5F6)),
  ('green', l10n.green, const Color(0xFF81C784)),
  ('purple', l10n.purple, const Color(0xFFCE93D8)),
];

Color _resolveAccentColor(String name) {
  return switch (name) {
    'theme' => AppColors.accent,
    'amber' => const Color(0xFFFFB300),
    'blue' => const Color(0xFF64B5F6),
    'green' => const Color(0xFF81C784),
    'purple' => const Color(0xFFCE93D8),
    _ => Colors.white,
  };
}

Future<void> _showManualScaleDialog(
  BuildContext context, {
  required double value,
  required double min,
  required double max,
  required ValueChanged<double> onChanged,
}) async {
  final submitted = await showLokalInputSheet(
    context: context,
    title: l10n.fontScale,
    message: l10n.enterAValueFromTo((min * 100).round(), (max * 100).round()),
    initialValue: (value * 100).round().toString(),
    confirmLabel: l10n.apply,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
  );
  final parsed = submitted == null ? null : double.tryParse(submitted);
  if (parsed != null) {
    onChanged((parsed / 100).clamp(min, max).toDouble());
  }
}

/// The accents as swatches, the chosen one ringed.
class _AccentPicker extends StatelessWidget {
  const _AccentPicker({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 14,
        runSpacing: 12,
        children: [
          for (final (id, label, color) in _accents())
            Semantics(
              button: true,
              selected: id == value,
              label: label,
              excludeSemantics: true,
              child: GestureDetector(
                onTap: () => onChanged(id),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 40,
                      height: 40,
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: id == value ? t.accent : t.border,
                          width: id == value ? 2 : 1,
                        ),
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      label.toUpperCase(),
                      style: LokalTheme.label(
                        t,
                        size: 9.5,
                        color: id == value ? t.text : t.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _WidgetTextPreview extends StatefulWidget {
  const _WidgetTextPreview({
    required this.titleBaseSp,
    required this.artistBaseSp,
    required this.manualScale,
    required this.accentColor,
    required this.centered,
  });

  final int titleBaseSp;
  final int artistBaseSp;
  final double manualScale;
  final Color accentColor;
  final bool centered;

  @override
  State<_WidgetTextPreview> createState() => _WidgetTextPreviewState();
}

class _WidgetTextPreviewState extends State<_WidgetTextPreview> {
  int _sizeIndex = 1;

  static const _autoFactors = [0.85, 1.0, 1.3];
  static const _sizeLabels = ['S', 'M', 'L'];

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final auto = _autoFactors[_sizeIndex];
    double clampSp(int base) =>
        (base * auto * widget.manualScale).round().clamp(9, 30).toDouble();
    final titleSp = clampSp(widget.titleBaseSp);
    final artistSp = clampSp(widget.artistBaseSp);
    final cross = widget.centered
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(l10n.preview.toUpperCase(), style: LokalTheme.label(t)),
              const Spacer(),
              LokalSegmented<int>(
                value: _sizeIndex,
                segments: [
                  for (final (i, label) in _sizeLabels.indexed)
                    LokalSegment(i, label),
                ],
                onChanged: (i) => setState(() => _sizeIndex = i),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // The widget itself is dark on the home screen whatever the theme.
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: cross,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.midnightCityDreams,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: LokalTheme.sans,
                    fontWeight: FontWeight.w700,
                    fontSize: titleSp,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.neonSkyline,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: LokalTheme.sans,
                    fontSize: artistSp,
                    color: widget.accentColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
