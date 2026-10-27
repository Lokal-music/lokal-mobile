import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum LogSource { dart, rust, crash, zone, platform }

class LogEntry {
  const LogEntry(this.timestamp, this.message, this.source);

  final DateTime timestamp;
  final String message;
  final LogSource source;
}

class AppLog extends ChangeNotifier {
  AppLog._() : _openLogFile = _defaultLogFile;
  @visibleForTesting
  AppLog.forTesting(this._openLogFile);
  static final AppLog instance = AppLog._();

  static const int maxEntries = 2000;
  static const int _maxFileBytes = 512 * 1024;
  static const Duration _flushInterval = Duration(seconds: 5);

  final List<LogEntry> _entries = [];
  final List<String> _pendingLines = [];
  File? _logFile;
  bool _persistenceInitialized = false;
  final Future<File> Function() _openLogFile;
  Timer? _flushTimer;
  Future<bool>? _flushInProgress;
  Future<void> _diskTail = Future<void>.value();
  int _clearRevision = 0;
  bool _disposed = false;

  static Future<File> _defaultLogFile() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, 'logs'));
    await directory.create(recursive: true);
    return File(p.join(directory.path, 'flick_log.jsonl'));
  }

  void _scheduleFlush() {
    // No repeating idle wakeup, including while a write is already draining.
    if (_disposed ||
        _logFile == null ||
        _pendingLines.isEmpty ||
        _flushTimer != null ||
        _flushInProgress != null) {
      return;
    }
    _flushTimer = Timer(_flushInterval, () {
      _flushTimer = null;
      unawaited(flushToDisk());
    });
  }

  Future<T> _serializeDisk<T>(Future<T> Function() operation) {
    final result = _diskTail.then((_) => operation());
    // Keep later operations possible after a failed operation; the caller still
    // receives the original failure through result.
    _diskTail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  List<LogEntry> get entries => _entries;

  void add(String message, {LogSource source = LogSource.dart}) {
    final entry = LogEntry(DateTime.now(), message, source);
    _entries.add(entry);
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    if (_persistenceInitialized) {
      _pendingLines.add(
        jsonEncode({
          't': entry.timestamp.millisecondsSinceEpoch,
          's': source.name,
          'm': message,
        }),
      );
      _scheduleFlush();
    }
    notifyListeners();
  }

  Future<void> initializePersistence() async {
    if (_persistenceInitialized) return;
    _persistenceInitialized = true;
    final revision = _clearRevision;
    try {
      final file = await _openLogFile();
      _logFile = file;
      if (revision != _clearRevision) {
        await _serializeDisk(() => _deleteFile(file));
      }
      await _replayPersisted();
      _scheduleFlush();
    } catch (error) {
      debugPrint('AppLog persistence unavailable: $error');
    }
  }

  Future<void> _replayPersisted() async {
    final revision = _clearRevision;
    final file = _logFile;
    if (file == null || !await file.exists()) return;
    try {
      final lines = await file.readAsLines();
      if (revision != _clearRevision) return;
      final start = math.max(0, lines.length - maxEntries);
      for (final line in lines.sublist(start)) {
        final entry = _decodeEntry(line);
        if (entry != null) {
          _entries.add(entry);
        }
      }
      if (_entries.length > maxEntries) {
        _entries.removeRange(0, _entries.length - maxEntries);
      }
      notifyListeners();
    } catch (error) {
      debugPrint('AppLog replay failed: $error');
    }
  }

  Future<void> flushToDisk() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    final active = _flushInProgress;
    if (active != null) {
      final succeeded = await active;
      if (succeeded && _pendingLines.isNotEmpty) await flushToDisk();
      return;
    }
    final file = _logFile;
    if (file == null || _pendingLines.isEmpty) return;
    final revision = _clearRevision;
    final flush = _serializeDisk(() => _drainPendingLines(file, revision));
    _flushInProgress = flush;
    try {
      await flush;
    } finally {
      _flushInProgress = null;
      _scheduleFlush();
    }
  }

  Future<bool> _drainPendingLines(File file, int revision) async {
    while (revision == _clearRevision && _pendingLines.isNotEmpty) {
      final lines = List<String>.of(_pendingLines);
      _pendingLines.clear();
      try {
        await file.writeAsString(
          '${lines.join('\n')}\n',
          mode: FileMode.append,
          flush: true,
        );
      } catch (error) {
        // Clear must not resurrect a failed, already-discarded batch.
        final discarded = revision != _clearRevision;
        if (!discarded) _pendingLines.insertAll(0, lines);
        debugPrint('AppLog flush failed: $error');
        return discarded;
      }
      if (revision != _clearRevision) return true;
      try {
        if (await file.length() > _maxFileBytes) await _trimFile(file);
      } catch (error) {
        // The append succeeded. Requeueing it after a trim failure duplicates
        // persisted entries; leave trimming for a later write instead.
        debugPrint('AppLog trim failed: $error');
      }
    }
    return true;
  }

  Future<void> _trimFile(File file) async {
    final lines = await file.readAsLines();
    final keep = lines.length > maxEntries
        ? lines.sublist(lines.length - maxEntries)
        : lines;
    await file.writeAsString('${keep.join('\n')}\n', flush: true);
  }

  LogEntry? _decodeEntry(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return null;
      final timestamp = decoded['t'];
      final message = decoded['m'];
      final sourceName = decoded['s'];
      if (timestamp is! int || message is! String) return null;
      return LogEntry(
        DateTime.fromMillisecondsSinceEpoch(timestamp),
        message,
        LogSource.values.firstWhere(
          (value) => value.name == sourceName,
          orElse: () => LogSource.dart,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  void clear() {
    _clearRevision++;
    _entries.clear();
    _pendingLines.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
    final file = _logFile;
    if (file != null) {
      // Delete behind the old write and before any later append. New entries
      // cannot be swallowed by a late delete or by the retired batch's retry.
      unawaited(_serializeDisk(() => _deleteFile(file)));
    }
    notifyListeners();
  }

  Future<void> _deleteFile(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (error) {
      debugPrint('AppLog delete failed: $error');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    super.dispose();
  }
}
