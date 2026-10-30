import 'dart:async';

import 'package:flick/providers/ios_transfer_provider.dart';
import 'package:flick/services/ios_transfer_import_coordinator.dart';
import 'package:flick/services/ios_transfer_session.dart';
import 'package:flick/services/ios_transfer_transport.dart';
import 'package:flick/widgets/common/ios_transfer_root.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingSession extends IosTransferSession {
  factory _RecordingSession() {
    final native = IosTransferTransport(supported: false);
    return _RecordingSession._(native);
  }
  _RecordingSession._(IosTransferTransport native)
    : super(
        native: native,
        coordinator: IosTransferImportCoordinator(
          native: native,
          store: () =>
              throw StateError('Lifetime fixture never opens user storage'),
          readMedia: (
            lease, {
            required isCurrent,
            required validateOwnership,
            cancelled,
          }) => throw StateError('Lifetime fixture never reads user audio'),
        ),
      );

  int starts = 0, foregrounds = 0, disposals = 0;
  final disposed = Completer<void>();
  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<void> foreground() async {
    foregrounds++;
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await super.dispose();
    if (!disposed.isCompleted) disposed.complete();
  }
}

void main() {
  testWidgets(
    'widget replacement borrows one app owner; only the container retires it',
    (tester) async {
      final session = _RecordingSession();
      var factories = 0;
      final container = ProviderContainer(
        overrides: [
          iosTransferSessionFactoryProvider.overrideWithValue(() {
            factories++;
            return session;
          }),
        ],
      );
      Widget host() => UncontrolledProviderScope(
        container: container,
        child: const IosTransferRoot(child: SizedBox()),
      );
      try {
        await tester.pumpWidget(host());
        expect(factories, 1);
        expect(session.starts, 1);
        expect(container.read(iosTransferSessionProvider), same(session));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        final foregrounds = session.foregrounds;
        expect(foregrounds, greaterThan(0));

        final entered = Completer<void>(), release = Completer<void>();
        final firstMutation = session.mutations.run<void>(
          pause: () async {},
          resume: () async {},
          mutate: () async {
            entered.complete();
            await release.future;
          },
        );
        await entered.future;
        await tester.pumpWidget(const SizedBox());
        expect(session.disposals, 0);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(session.foregrounds, foregrounds);

        await tester.pumpWidget(host());
        expect(factories, 1);
        expect(session.starts, 2);
        expect(session.disposals, 0);
        var secondStarted = false;
        final secondMutation = container
            .read(iosTransferSessionProvider)!
            .mutations
            .run<void>(
              pause: () async {},
              resume: () async {},
              mutate: () async {
                secondStarted = true;
              },
            );
        await tester.pump();
        expect(secondStarted, false);
        release.complete();
        await Future.wait([firstMutation, secondMutation]);
        expect(secondStarted, true);
        await tester.pumpWidget(const SizedBox());
      } finally {
        container.dispose();
        await session.disposed.future;
      }
      expect(session.disposals, 1);
    },
  );

  testWidgets('unsupported app owner leaves lifecycle and child usable', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        iosTransferSessionFactoryProvider.overrideWithValue(() => null),
      ],
    );
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const IosTransferRoot(child: SizedBox(key: ValueKey('child'))),
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byKey(const ValueKey('child')), findsOneWidget);
      expect(container.read(iosTransferSessionProvider), isNull);
      await tester.pumpWidget(const SizedBox());
    } finally {
      container.dispose();
    }
  });
}
