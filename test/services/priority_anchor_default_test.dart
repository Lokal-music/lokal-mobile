import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/services/app_preferences_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('priority anchor is disabled unless explicitly enabled', () async {
    final service = AppPreferencesService();
    expect(const AppPreferences().priorityAnchorEnabled, isFalse);
    expect(await service.getPriorityAnchorEnabled(), isFalse);
    expect((await service.getPreferences()).priorityAnchorEnabled, isFalse);
  });

  test('opted-in priority anchor preference survives reload', () async {
    final service = AppPreferencesService();
    await service.setPriorityAnchorEnabled(true);

    expect(await service.getPriorityAnchorEnabled(), isTrue);
    expect((await service.getPreferences()).priorityAnchorEnabled, isTrue);

    await service.setPriorityAnchorEnabled(false);
    expect(await service.getPriorityAnchorEnabled(), isFalse);
    expect((await service.getPreferences()).priorityAnchorEnabled, isFalse);
  });

  test('existing explicit true preference remains opted in', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'app_priority_anchor_enabled': true,
    });

    final service = AppPreferencesService();
    expect(await service.getPriorityAnchorEnabled(), isTrue);
    expect((await service.getPreferences()).priorityAnchorEnabled, isTrue);
  });
}
