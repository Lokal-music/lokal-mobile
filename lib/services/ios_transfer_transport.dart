import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';

import '../models/ios_transfer_models.dart';
import 'link/link_protocol.dart' show linkUuid;

Uint8List _prepareIntents(List<IosTransferIntent> intents) {
  if (intents.isEmpty ||
      intents.length > iosTransferMaximumJobs ||
      intents.map((intent) => intent.id).toSet().length != intents.length) {
    throw const FormatException('Invalid transfer batch.');
  }
  for (final intent in intents) {
    intent.validate(submission: true);
    if ((intent.expectedBytes ?? 0) > 8 * 1024 * 1024 * 1024) {
      throw const FormatException('Transfer file exceeds its size limit.');
    }
  }
  final bytes = Uint8List.fromList(
    utf8.encode(jsonEncode([for (final intent in intents) intent.toJson()])),
  );
  if (bytes.length > iosTransferMaximumBytes) {
    throw const FormatException('Transfer request exceeds its byte limit.');
  }
  return bytes;
}

/// One application coordinator owns this transport. Native storage/networking
/// survives Dart/engine replacement; this class owns only typed calls and the
/// foreground change subscription. No credentials or durable Dart journal.
class IosTransferTransport {
  IosTransferTransport({
    this.channel = const MethodChannel('lokal/transfers'),
    bool? supported,
  }) : supported = supported ?? Platform.isIOS {
    _changes = StreamController<void>.broadcast(
      onListen: () => unawaited(_start()),
      onCancel: () => unawaited(_stop()),
    );
  }

  static final _owners = <(BinaryMessenger, String), IosTransferTransport>{};
  final MethodChannel channel;
  final bool supported;
  late final StreamController<void> _changes;
  bool _disposed = false;
  String? _subscription;
  (BinaryMessenger, String) get _key => (channel.binaryMessenger, channel.name);
  Stream<void> get changes => _changes.stream;

  Future<Object?> _call(String method, [Object? payload]) async {
    if (!supported || _disposed) {
      throw StateError('Native transfer transport unavailable.');
    }
    final Uint8List? bytes;
    if (payload == null) {
      bytes = null;
    } else {
      bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
      final budget = method == 'enqueue' ? iosTransferMaximumBytes : 8192;
      if (bytes.length > budget) {
        throw const FormatException('Transfer request exceeds its byte limit.');
      }
    }
    return _invoke(method, bytes);
  }

  Future<Object?> _invoke(String method, Uint8List? bytes) async {
    if (!supported || _disposed) {
      throw StateError('Native transfer transport unavailable.');
    }
    final raw = await channel.invokeMethod<Object?>(method, bytes);
    if (raw is! Uint8List ||
        raw.isEmpty ||
        raw.length > iosTransferMaximumBytes) {
      throw const FormatException('Invalid native transfer response.');
    }
    try {
      return jsonDecode(utf8.decode(raw, allowMalformed: false));
    } on FormatException {
      // JSON exceptions otherwise quote the response, including music metadata.
      throw const FormatException('Invalid native transfer response.');
    }
  }

  Future<IosTransferCapability> capability() async {
    if (!supported) return const IosTransferCapability(available: false);
    try {
      return IosTransferCapability.fromJson(await _call('capability'));
    } on MissingPluginException {
      return const IosTransferCapability(available: false);
    }
  }

  Future<IosTransferPairing?> currentPairing() async {
    final raw = await _call('currentPairing');
    return raw == null ? null : IosTransferPairing.fromJson(raw);
  }

  Future<IosTransferSummary> summary() async =>
      IosTransferSummary.fromJson(await _call('summary'));
  Future<IosTransferSummary> recover() async =>
      IosTransferSummary.fromJson(await _call('recover'));

  Future<List<IosTransferJob>> page({int offset = 0, int limit = 100}) async {
    if (offset < 0 ||
        offset > iosTransferMaximumJobs ||
        limit < 1 ||
        limit > 100) {
      throw const FormatException('Invalid transfer page.');
    }
    final raw = await _call('page', {'offset': offset, 'limit': limit});
    if (raw is! List || raw.length > limit) {
      throw const FormatException('Invalid native transfer page.');
    }
    return List.unmodifiable(raw.map(IosTransferJob.fromJson));
  }

  Future<IosTransferSummary> enqueue(List<IosTransferIntent> intents) async {
    if (!supported || _disposed) {
      throw StateError('Native transfer transport unavailable.');
    }
    // Freeze consent before the first await; large plans are validated/encoded
    // away from the audio/UI isolate and submitted as one native transaction.
    final frozen = List<IosTransferIntent>.unmodifiable(intents);
    final bytes = await Isolate.run(() => _prepareIntents(frozen));
    return IosTransferSummary.fromJson(await _invoke('enqueue', bytes));
  }

  Future<IosTransferJob> _control(String method, IosTransferJob job) async {
    return IosTransferJob.fromJson(
      await _call(method, {'id': job.id, 'revision': job.revision}),
    );
  }

  Future<IosTransferJob> cancel(IosTransferJob job) => _control('cancel', job);
  Future<IosTransferJob> retry(IosTransferJob job) => _control('retry', job);
  Future<IosTransferJob> verify(IosTransferJob job) => _control('verify', job);

  Future<IosTransferSummary> resume(IosTransferScope scope) async {
    scope.validate();
    return IosTransferSummary.fromJson(await _call('resume', scope.toJson()));
  }

  Future<void> _start() async {
    if (!supported || _disposed) return;
    final id = linkUuid();
    _subscription = id;
    _owners[_key] = this;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'changed' || call.arguments != null) {
        throw MissingPluginException();
      }
      if (!_disposed &&
          identical(_owners[_key], this) &&
          _subscription == id &&
          !_changes.isClosed) {
        _changes.add(null);
      }
    });
    try {
      await channel.invokeMethod<void>(
        'observe',
        Uint8List.fromList(utf8.encode(jsonEncode({'clientID': id}))),
      );
      if (_disposed || _subscription != id || !identical(_owners[_key], this)) {
        await _stopNative(id);
      }
    } catch (error, stack) {
      if (!_disposed &&
          _subscription == id &&
          identical(_owners[_key], this) &&
          !_changes.isClosed) {
        _changes.addError(error, stack);
      }
    }
  }

  Future<void> _stopNative(String id) async {
    await channel.invokeMethod<void>(
      'stopObserving',
      Uint8List.fromList(utf8.encode(jsonEncode({'clientID': id}))),
    );
  }

  Future<void> _stop() async {
    final id = _subscription;
    _subscription = null;
    if (!supported || id == null) return;
    if (identical(_owners[_key], this)) {
      _owners.remove(_key);
      channel.setMethodCallHandler(null);
    }
    try {
      await _stopNative(id);
    } on MissingPluginException {
      // An engine from before this protocol has no native observation to stop.
    } on PlatformException {
      // Detaching the UI does not revoke persisted jobs or the native owner.
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _stop();
    await _changes.close();
  }
}
