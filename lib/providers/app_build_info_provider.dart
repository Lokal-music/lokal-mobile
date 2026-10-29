import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AppBuildInfo {
  const AppBuildInfo({required this.version, required this.build});
  final String version;
  final String build;
  String get identity => '$version+$build';
  String get label => '$version (build $build)';
}

/// Read installed app metadata (APK or iPhone bundle), including build-name/number
/// overrides. Never substitute the legacy upstream marketing constants.
final appBuildInfoProvider = FutureProvider<AppBuildInfo>((ref) async {
  final result = await const MethodChannel('lokal/app_info')
      .invokeMapMethod<String, dynamic>('get');
  final version = result?['version'] as String?;
  final build = result?['build']?.toString();
  if (version == null || build == null) {
    throw StateError('Installed build metadata unavailable');
  }
  return AppBuildInfo(version: version, build: build);
});
