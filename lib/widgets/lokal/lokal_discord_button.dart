import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/widgets/lokal/lokal_glass.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// The community invite shared with the desktop app and project README.
const lokalDiscordInvite = 'https://discord.com/invite/8bUGWChwpG';

/// The same glass header action on Home, Library and You.
class LokalDiscordButton extends StatelessWidget {
  const LokalDiscordButton({super.key});

  Future<void> _open(BuildContext context) async {
    try {
      if (await launchUrl(
        Uri.parse(lokalDiscordInvite),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      // A missing external handler must not break the current page.
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Discord: ${lokalText('Try again in a moment.')}'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Discord',
    excludeFromSemantics: true,
    child: LokalGlassButton(
      semanticLabel: 'Discord',
      onPressed: () => _open(context),
      child: Icon(Icons.discord, color: context.lokal.text),
    ),
  );
}
