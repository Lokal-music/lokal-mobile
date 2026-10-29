import 'package:flick/l10n/l10n.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/providers/app_build_info_provider.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/widgets/lokal/lokal_logo.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';

/// The package name Flick's licence is registered under.
const lokalUpstreamPackage = 'Flick';

/// How a package is named in the list: Flick is labelled as the project
/// Lokal grew from.
String lokalLicencePackageLabel(String package) =>
    package == lokalUpstreamPackage ? 'Flick (upstream project)' : package;

/// The open-source licences, in Lokal's settings look: Lokal's own licence
/// first, then every package with how many licences it carries.
class LokalLicencesPage extends ConsumerStatefulWidget {
  const LokalLicencesPage({super.key, this.licences});

  /// Replaces [LicenseRegistry.licenses], for tests.
  @visibleForTesting
  final Stream<LicenseEntry>? licences;

  @override
  ConsumerState<LokalLicencesPage> createState() => _LokalLicencesPageState();
}

class _LokalLicencesPageState extends ConsumerState<LokalLicencesPage> {
  final _packages = <String, List<LicenseEntry>>{};
  StreamSubscription<LicenseEntry>? _sub;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _sub = (widget.licences ?? LicenseRegistry.licenses).listen(
      (entry) {
        if (!mounted) return;
        setState(() {
          for (final package in entry.packages) {
            (_packages[package] ??= []).add(entry);
          }
        });
      },
      onDone: () {
        if (mounted) setState(() => _done = true);
      },
      onError: (_) {
        if (mounted) setState(() => _done = true);
      },
    );
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  List<String> get _sorted {
    final names = _packages.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    // The project Lokal grew from comes first.
    if (names.remove(lokalUpstreamPackage)) {
      names.insert(0, lokalUpstreamPackage);
    }
    return names;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final names = _sorted;
    return LokalSettingsScaffold(
      title: lokalText('Licences'),
      subtitle: lokalText('The open-source software Lokal is built with.'),
      children: [
        LokalSettingsBlock(
          top: 16,
          child: LokalSettingsCard(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const LokalLogo(size: 44),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        lokalText(
                          "Lokal {arg0}",
                          args: {
                            'arg0': ref
                                .watch(appBuildInfoProvider)
                                .when(
                                  data: (info) => info.version,
                                  loading: () => '…',
                                  error: (_, _) => lokalText('Unavailable'),
                                ),
                          },
                        ),
                        style: TextStyle(
                          fontFamily: LokalTheme.sans,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: t.text,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        lokalText(
                          "Free software under the GNU GPL v3. Lokal grew from Flick, whose MIT notice is kept below.",
                        ),
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: t.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (names.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: _done
                  ? Text(
                      lokalText('No licences found.'),
                      style: TextStyle(color: t.muted),
                    )
                  : SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: t.accent,
                      ),
                    ),
            ),
          )
        else
          LokalSettingsSection(
            title: lokalText('Packages'),
            heading: 'Packages · ${names.length}',
            children: [
              for (final name in names)
                LokalSettingLink(
                  label: lokalLicencePackageLabel(name),
                  value: '${_packages[name]!.length}',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _LicenceDetailPage(
                        package: name,
                        entries: _packages[name]!,
                      ),
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _LicenceDetailPage extends StatelessWidget {
  const _LicenceDetailPage({required this.package, required this.entries});

  final String package;
  final List<LicenseEntry> entries;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return LokalSettingsScaffold(
      title: lokalLicencePackageLabel(package),
      subtitle: package == lokalUpstreamPackage
          ? lokalText(
              'The project Lokal grew from. Its code keeps this notice.',
            )
          : null,
      children: [
        for (final entry in entries)
          LokalSettingsBlock(
            top: 16,
            child: LokalSettingsCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final paragraph in entry.paragraphs)
                    Padding(
                      padding: EdgeInsets.only(
                        left:
                            paragraph.indent == LicenseParagraph.centeredIndent
                            ? 0
                            : 12.0 * paragraph.indent,
                        bottom: 10,
                      ),
                      child: Text(
                        paragraph.text,
                        textAlign:
                            paragraph.indent == LicenseParagraph.centeredIndent
                            ? TextAlign.center
                            : TextAlign.start,
                        style: TextStyle(
                          fontFamily: LokalTheme.sans,
                          fontSize: 12.5,
                          height: 1.45,
                          color: t.text,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
