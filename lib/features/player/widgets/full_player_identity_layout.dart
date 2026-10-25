import 'package:flutter/material.dart';

/// Fixed identity-row geometry for the full player.
///
/// The overflowing title uses an explicit height while ordinary titles use
/// their font's intrinsic line box. Without one common slot, switching between
/// those tracks changes the artist row's y position and the quality pill
/// visibly jumps during the track-to-track crossfade.
class FullPlayerIdentityLayout extends StatelessWidget {
  const FullPlayerIdentityLayout({
    super.key,
    required this.title,
    required this.artist,
    required this.titleFontSize,
    required this.titleToArtistGap,
    this.trailing = const <Widget>[],
  });

  final Widget title;
  final Widget artist;
  final List<Widget> trailing;
  final double titleFontSize;
  final double titleToArtistGap;

  static double titleHeight(BuildContext context, double fontSize) =>
      MediaQuery.textScalerOf(context).scale(fontSize * 1.35) + 2;

  static double metadataHeight(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(30);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        height: titleHeight(context, titleFontSize),
        child: Align(
          alignment: Alignment.centerLeft,
          child: title,
        ),
      ),
      SizedBox(height: titleToArtistGap),
      SizedBox(
        height: metadataHeight(context),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: artist,
              ),
            ),
            ...trailing,
          ],
        ),
      ),
    ],
  );
}
