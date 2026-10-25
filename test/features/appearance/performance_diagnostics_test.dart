import 'package:flick/features/appearance/lokal_performance_advisor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('foreground diagnostics continue after the suggestion window', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('com.mossapps.flick/diagnostics');
    var snapshots = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      _,
    ) async {
      snapshots++;
      return {'cpuMs': snapshots * 10, 'manufacturer': 'test', 'model': 'test'};
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: LokalPerformanceAdvisor(child: SizedBox())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(minutes: 2));
    final afterSuggestion = snapshots;
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(snapshots, greaterThan(afterSuggestion));
    await tester.pumpWidget(const SizedBox());
    final afterDispose = snapshots;
    await tester.pump(const Duration(seconds: 30));
    expect(snapshots, afterDispose);
  });
}
