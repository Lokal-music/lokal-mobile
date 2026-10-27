import 'package:flutter/material.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/features/discovery/youtube_music_sign_in.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';

/// Opt-in YouTube Music account connection, separate from catalog search.
class YoutubeMusicSettingsTile extends ConsumerStatefulWidget {
  const YoutubeMusicSettingsTile({super.key});

  @override
  ConsumerState<YoutubeMusicSettingsTile> createState() =>
      _YoutubeMusicSettingsTileState();
}

class _YoutubeMusicSettingsTileState
    extends ConsumerState<YoutubeMusicSettingsTile> {
  bool _busy = false;

  Future<void> _activate() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final current = ref.read(konnektedYoutubeMusicSessionProvider).value;
      if (current == null) {
        final session = await YoutubeMusicSignInSheet.show(context);
        if (!mounted || session == null) return;
        await ref
            .read(konnektedYoutubeMusicSessionProvider.notifier)
            .save(session);
      } else {
        final signOut = await showLokalConfirmSheet(
          context: context,
          title: 'Sign out of YouTube Music?',
          message: 'This removes the saved account session from this device.',
          confirmLabel: 'Sign out',
          destructive: true,
        );
        if (!mounted || !signOut) return;
        try {
          await CookieManager.instance().deleteAllCookies();
        } catch (_) {
          // The secure app session must still be cleared if WebView cleanup fails.
        }
        await ref.read(konnektedYoutubeMusicSessionProvider.notifier).signOut();
      }
    } catch (_) {
      if (mounted) {
        LokalToast.fromSnackBar(context, 
          const SnackBar(
            content: Text(
              'Could not update the YouTube Music account session.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(konnektedYoutubeMusicSessionProvider);
    final signedIn = session.value?.signedIn == true;
    final subtitle = session.when(
      data: (value) => value?.signedIn == true
          ? 'Signed in · Account Discovery available'
          : 'Connect to load your mixes, Likes and history',
      loading: () => 'Checking saved session…',
      error: (_, _) => 'Session could not be read',
    );
    final busy = _busy || session.isLoading;
    return LokalSettingRow(
      label: 'YouTube',
      description: subtitle,
      onTap: busy ? null : _activate,
      trailing: busy
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: context.lokal.accent,
              ),
            )
          : LokalSettingButton(
              label: signedIn ? 'Sign out' : 'Sign in',
              onPressed: _activate,
            ),
    );
  }
}
