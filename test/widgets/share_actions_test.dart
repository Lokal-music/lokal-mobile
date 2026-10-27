import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flick/core/theme/app_theme.dart';
import 'package:flick/core/utils/app_log.dart';
import 'package:flick/features/player/widgets/share/share_bottom_sheet.dart';
import 'package:flick/features/settings/screens/logs_screen.dart';
import 'package:flick/features/songs/widgets/song_actions_bottom_sheet.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/album_color_provider.dart';
import 'package:flick/providers/favorites_provider.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

const _song = Song(
  id: 'share_test',
  title: '夜曲',
  artist: 'Test Artist',
  duration: Duration(minutes: 3),
  fileType: 'FLAC',
);
const _shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

Widget _host(Widget child) => ProviderScope(
  overrides: [
    albumDominantColorSyncProvider.overrideWithValue(null),
    isSongFavoriteProvider(_song.id).overrideWithValue(false),
  ],
  child: MaterialApp(
    theme: AppTheme.darkTheme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: kSupportedLocales,
    home: Scaffold(body: child),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temp;
  late List<MethodCall> shares;
  late Completer<void> shared;
  late FilePickerPlatform originalPicker;
  Object? shareError;

  setUpAll(() async {
    await (FontLoader('GoogleSansFlex')
          ..addFont(rootBundle.load('assets/fonts/GoogleSansFlex-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/GoogleSansFlex-Bold.ttf')))
        .load();
    await (FontLoader('NotoSansSC')
          ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf')))
        .load();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    LocaleController.instance.bindLocale(const Locale('en'));
    temp = await Directory.systemTemp.createTemp('share_actions_test_');
    shares = [];
    shared = Completer<void>();
    shareError = null;
    originalPicker = FilePickerPlatform.instance;
    AppLog.instance.clear();
    AppLog.instance.entries.addAll([
      LogEntry(DateTime(2026, 10, 14, 1, 2, 3, 4), 'keep 夜曲', LogSource.dart),
      LogEntry(DateTime(2026, 10, 14, 1, 2, 4), 'omit this', LogSource.rust),
    ]);
    messenger.setMockMethodCallHandler(_pathChannel, (_) async => temp.path);
    messenger.setMockMethodCallHandler(_shareChannel, (call) async {
      shares.add(call);
      if (!shared.isCompleted) shared.complete();
      if (shareError != null) throw shareError!;
      return ''; // Dismissing the native sheet is a normal result.
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(_shareChannel, null);
    messenger.setMockMethodCallHandler(_pathChannel, null);
    FilePickerPlatform.instance = originalPicker;
    AppLog.instance.clear();
    await temp.delete(recursive: true);
  });

  Future<void> tapAndShare(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await drainUntil(tester, () => shared.isCompleted);
    await tester.pumpAndSettle();
    expect(shares.last.method, 'share');
  }

  testWidgets('log share keeps filtered UTF-8 contents, filename and subject', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const LogsScreen()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'keep');
    await tapAndShare(tester, find.byTooltip(l10n.share));

    final args = shares.single.arguments as Map;
    final path = (args['paths'] as List).single as String;
    expect(p.basename(path), matches(r'^lokal_logs_.*\.txt$'));
    expect(args['subject'], 'Lokal logs');
    expect(args['mimeTypes'], ['text/plain']);
    expect(args['text'], isNull);
    expect(
      await tester.runAsync(() => File(path).readAsString()),
      '01:02:03.004 [dart] keep 夜曲',
    );
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('empty log filter does not open the share sheet', (tester) async {
    await tester.pumpWidget(_host(const LogsScreen()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'no matching entry');
    await tester.tap(find.byTooltip(l10n.share));
    await tester.pumpAndSettle();
    expect(shares, isEmpty);
  });

  testWidgets('log share failure still shows the existing error', (tester) async {
    shareError = PlatformException(code: 'share_failed', message: 'test failure');
    await tester.pumpWidget(_host(const LogsScreen()));
    await tester.pumpAndSettle();
    await tapAndShare(tester, find.byTooltip(l10n.share));
    expect(find.text(l10n.shareFailed(shareError!)), findsOneWidget);
    LokalToast.dismiss();
    await tester.pumpAndSettle();
  });

  for (final contentUri in [false, true]) {
    testWidgets('saved logs re-share exact export for ${contentUri ? 'content' : 'file'} URI', (
      tester,
    ) async {
      final destination = contentUri
          ? Uri.parse('content://documents/document/42')
          : Uri.file(p.join(temp.path, 'chosen logs.txt'));
      final picker = _SavePicker(destination);
      FilePickerPlatform.instance = picker;
      await tester.pumpWidget(_host(const LogsScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l10n.more));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.saveAsText));
      await tester.pumpAndSettle();
      expect(picker.mimeType, 'text/plain');
      expect(picker.fileName, matches(r'^lokal_logs_.*\.txt$'));
      await tapAndShare(tester, find.text(l10n.share));

      final args = shares.single.arguments as Map;
      final sharedPath = (args['paths'] as List).single as String;
      expect(args['subject'], 'Lokal logs');
      expect(args['mimeTypes'], ['text/plain']);
      // Save destinations are platform document identifiers. Re-sharing uses
      // the exact exported bytes/name for either kind of picker result (#260).
      expect(p.basename(sharedPath), picker.fileName);
      expect(
        await tester.runAsync(() => File(sharedPath).readAsBytes()),
        picker.bytes,
      );
      expect(utf8.decode(picker.bytes!), contains('keep 夜曲'));
    });
  }

  testWidgets('cancelling save does not offer or invoke sharing', (tester) async {
    FilePickerPlatform.instance = _SavePicker(null);
    await tester.pumpWidget(_host(const LogsScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(l10n.more));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.saveAsText));
    await tester.pumpAndSettle();
    expect(find.text(l10n.saved), findsNothing);
    expect(shares, isEmpty);
  });

  testWidgets('uploaded log link shares text and subject after consent', (
    tester,
  ) async {
    const url = 'https://dpaste.com/TEST';
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(_host(const LogsScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l10n.more));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.copyLink));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      await tester.tap(find.text(l10n.upload));
      await drainUntil(tester, () => find.text(url).evaluate().isNotEmpty);
      expect(requests, hasLength(1));
      expect(find.text(url), findsOneWidget);
      await tapAndShare(tester, find.text(l10n.share));
    }, () => MockClient((request) async {
      requests.add(request);
      return http.Response('$url\n', 201);
    }));
    expect(shares.single.arguments, {'text': url, 'subject': 'Lokal logs'});
  });

  testWidgets('song share closes sheet and keeps the original audio path', (
    tester,
  ) async {
    final path = p.join(temp.path, '夜曲.flac');
    final song = _song.copyWith(filePath: path);
    await tester.pumpWidget(_host(Builder(
      builder: (context) => TextButton(
        onPressed: () => SongActionsBottomSheet.show(context, song),
        child: const Text('Open actions'),
      ),
    )));
    await tester.tap(find.text('Open actions'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(l10n.share));
    await tapAndShare(tester, find.text(l10n.share));
    expect(find.byType(SongActionsBottomSheet), findsNothing);
    final args = shares.single.arguments as Map;
    expect(args['paths'], [path]);
    expect(args['text'], isNull);
    expect(args['subject'], isNull);
  });

  for (final fail in [false, true]) {
    testWidgets('card share preserves PNG and caption${fail ? ' on retry' : ''}', (
      tester,
    ) async {
      if (fail) shareError = PlatformException(code: 'share_failed');
      await tester.pumpWidget(_host(
        // Use an explicit line height for the fixed-size card fixture; these
        // checks cover capture/sharing rather than inherited text layout.
        DefaultTextStyle.merge(
          style: const TextStyle(height: 1),
          child: const ShareBottomSheet(song: _song),
        ),
      ));
      await drainUntil(
        tester,
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      await tester.pumpAndSettle();
      await tapAndShare(tester, find.text(l10n.share).last);
      if (fail) {
        expect(find.text(l10n.shareFailed(shareError!)), findsOneWidget);
        shareError = null;
        shared = Completer<void>();
        await tapAndShare(tester, find.text(l10n.share).last);
        expect(shares, hasLength(2));
      }
      final args = shares.last.arguments as Map;
      final path = (args['paths'] as List).single as String;
      expect(p.basename(path), 'konnekted-card.png');
      expect(args['mimeTypes'], ['image/png']);
      expect(args['text'], '${_song.title} — ${_song.artist}\nKonnekted');
      if (fail) {
        final firstPath = (shares.first.arguments as Map)['paths'].single;
        expect(path, isNot(firstPath), reason: 'Retry must use a fresh export');
      }
      final bytes = await tester.runAsync(() => File(path).readAsBytes());
      expect(bytes!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  }
}

// Image encoding and file I/O use real async work; dialog results resume on
// the test clock. Advance both rather than awaiting one while starving the other.
Future<void> drainUntil(WidgetTester tester, bool Function() complete) async {
  await tester.pump();
  for (var i = 0; i < 200 && !complete(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(complete(), isTrue, reason: 'The asynchronous action did not complete');
}

class _SavePicker extends FilePickerPlatform {
  _SavePicker(this.destination);
  final Uri? destination;
  String? fileName;
  String? mimeType;
  Uint8List? bytes;

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    this.fileName = fileName;
    this.mimeType = mimeType;
    this.bytes = bytes;
    if (destination?.scheme == 'file') {
      File.fromUri(destination!).writeAsBytesSync(bytes);
    }
    return destination;
  }
}
