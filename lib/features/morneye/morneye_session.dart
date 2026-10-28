import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'morneye_network.dart';
import 'morneye_storage.dart';

/// A signed gateway session, as desktop's electron/morneye/session.js. Most
/// official add-ons (Deezer, Qobuz, Tidal, Amazon) reach their service through
/// a gateway that first asks you to pass a verification page once; after that
/// every request is HMAC-signed with the session it granted.

String _sha256(List<int> value) => sha256.convert(value).toString();

String _hmac(List<int> key, String value) => base64Url
    .encode(Hmac(sha256, key).convert(utf8.encode(value)).bytes)
    .replaceAll('=', '');

String _randomHex(int bytes) =>
    morneyeRandomBytes(bytes)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

String _randomToken(int bytes) =>
    base64Url.encode(morneyeRandomBytes(bytes)).replaceAll('=', '');

/// The signature headers for one request.
Map<String, String> morneyeSignedHeaders(
  Map<String, Object?> config,
  Map<String, Object?> record,
  String method,
  String url,
  String body, {
  DateTime? now,
  String? nonce,
}) {
  final at = (now ?? DateTime.now()).toUtc();
  final prefix = config['headerPrefix'] as String? ?? 'X-Sig-';
  // JavaScript's toISOString: milliseconds only, while Dart may add micros.
  final timestamp = at.toIso8601String().replaceFirstMapped(
    RegExp(r'\.(\d{3})\d*Z$'),
    (match) => '.${match[1]}Z',
  );
  final bodyHash = _sha256(utf8.encode(body));
  final windowSeconds = (config['timeWindowSeconds'] as num?)?.toInt() ?? 300;
  final window = at.millisecondsSinceEpoch ~/ 1000 ~/ windowSeconds;
  final sessionId = '${record['session_id']}';
  final rolling = _hmac(
    utf8.encode('${record['session_secret']}'),
    '$window:$sessionId',
  );
  final appVersion = config['appVersion'] as String? ?? 'ext-1.0';
  final platform = config['platform'] as String? ?? 'extension';
  final usedNonce = nonce ?? _randomHex(16);
  final canonical = [
    config['schemeLabel'] as String? ?? 'SPOTIFLAC-HMAC-V1',
    method.toUpperCase(),
    Uri.parse(url).path,
    '',
    bodyHash,
    timestamp,
    usedNonce,
    sessionId,
    appVersion,
    platform,
  ].join('\n');
  return {
    '${prefix}Session': sessionId,
    '${prefix}Timestamp': timestamp,
    '${prefix}Nonce': usedNonce,
    '${prefix}Body-SHA256': bodyHash,
    '${prefix}Signature': _hmac(utf8.encode(rolling), canonical),
    '${prefix}App-Version': appVersion,
    '${prefix}Platform': platform,
  };
}

class MorneyePending {
  MorneyePending(this.url, this.state, this.createdAt);
  final String url;
  final String state;
  final DateTime createdAt;
}

/// Expose the signed gateway's retry contract under the names consumed by
/// the installed Mornye/Tidal JS extensions. The raw gateway uses snake_case;
/// Tidal's signedJSON reads camelCase. Without these fields a terminal 403
/// ticket rejection looks like a transient failure, and the extension keeps
/// retrying quality tiers without ever opening an audio transfer.
///
/// Do not manufacture an authorization success or a playable URL.
Map<String, Object?> morneyeSignedAddonResponse(
  Map<String, Object?> response,
  Map<String, Object?> contract,
) {
  final status = (response['status'] as num?)?.toInt();
  final code = '${contract['code'] ?? ''}'.toUpperCase();
  final explicitMode = '${contract['retry_mode'] ?? ''}'.trim();
  // A 4xx response other than throttling/timeouts cannot become playable by
  // retrying the exact same signed ticket. A gateway can explicitly override
  // this with its retry contract.
  final terminalClientError = status != null &&
      status >= 400 && status < 500 && status != 408 && status != 429;
  final retryMode = explicitMode.isNotEmpty
      ? explicitMode : (terminalClientError ? 'none' : '');
  final retrySeconds = (contract['retry_after_seconds'] as num?)?.toDouble() ??
      0.0;
  return {
    ...response,
    'code': code,
    'retryable': contract['retryable'] == true && retryMode != 'none',
    'retryMode': retryMode,
    'retryAfterSeconds': retrySeconds,
    'needsVerification': status == 428 || code == 'VERIFY_REQUIRED',
    // Retain backwards-compatible snake_case fields for other clients.
    if (code.isNotEmpty) ...{
      'error_code': code,
      'error_origin': contract['origin'],
      'error_action': contract['action'],
      'retry_after_seconds': retrySeconds,
    },
  };
}

class MorneyeSignedSession {
  MorneyeSignedSession(this.config, this.storage, this.network, String owner)
    : namespace = _sha256(
        utf8.encode(
          [
            config['namespace'] as String? ?? owner,
            config['baseUrl'],
            config['appVersion'] as String? ?? 'ext-1.0',
            config['platform'] as String? ?? 'extension',
          ].join('\n'),
        ),
      );

  final Map<String, Object?> config;
  final MorneyeStorage storage;
  final MorneyeNetwork? network;
  final String namespace;

  MorneyePending? pending;
  String? pendingGrant;
  bool blocked = false;
  int _generation = 0;
  Future<bool>? _flight;
  Future<Map<String, Object?>>? _exchange;
  Future<void>? _refreshing;

  String get _appVersion => config['appVersion'] as String? ?? 'ext-1.0';
  String get _platform => config['platform'] as String? ?? 'extension';
  Map get _endpoints =>
      config['endpoints'] is Map ? config['endpoints'] as Map : const {};
  String get _callbackUrl =>
      config['callbackUrl'] as String? ?? 'spotiflac://session-grant';

  MorneyeNetwork get _network {
    final value = network;
    if (value == null) throw StateError('Signed session has no network');
    return value;
  }

  Map<String, Object?> record() {
    final record = storage.read(namespace, 'session');
    if (record['install_id'] == null) {
      record['install_id'] = _randomHex(16);
      _save(record);
    }
    return record;
  }

  void _save(Map<String, Object?> record) =>
      storage.write(namespace, 'session', record);

  bool usable(Map<String, Object?> record) {
    final expires = DateTime.tryParse('${record['expires_at'] ?? ''}');
    return record['session_id'] != null &&
        record['session_secret'] != null &&
        expires != null &&
        expires.isAfter(DateTime.now());
  }

  /// [path] under the configured base URL; never outside it.
  String endpoint(String path) {
    final base = Uri.parse(config['baseUrl'] as String);
    final trimmed = base.toString().replaceFirst(RegExp(r'/$'), '');
    final url = Uri.parse('$trimmed/${path.replaceFirst(RegExp(r'^/+'), '')}');
    final basePath = base.path.replaceFirst(RegExp(r'/$'), '');
    if (url.origin != base.origin || !url.path.startsWith('$basePath/')) {
      throw StateError('Signed-session path escaped its base URL');
    }
    return url.toString();
  }

  Map<String, Object?> status() {
    final record = this.record();
    return {
      'authenticated': usable(record) && !blocked,
      'verification_required': pending != null,
      'expires_at': record['expires_at'] ?? '',
      'session_id': record['session_id'] ?? '',
      'install_id': record['install_id'],
      'app_version': _appVersion,
      'platform': _platform,
      'auth_url': pending?.url ?? '',
    };
  }

  Map<String, Object?> clear() {
    final record = this.record();
    _generation++;
    _save({'install_id': record['install_id']});
    pending = null;
    blocked = false;
    return {'success': true};
  }

  Map<String, Object?> verification() => {
    'ok': false,
    'needsVerification': true,
    'error': 'VERIFY_REQUIRED',
    'auth_url': pending?.url ?? '',
    'open_auth_url': pending?.url ?? '',
  };

  /// Asks the gateway for a session; false when a verification page must be
  /// passed first ([pending] then holds its URL).
  Future<bool> bootstrap() =>
      _flight ??= _bootstrap().whenComplete(() => _flight = null);

  Future<bool> _bootstrap() async {
    final generation = _generation;
    final record = this.record();
    final url =
        Uri.parse(endpoint(_endpoints['bootstrap'] as String? ?? '/bootstrap'))
            .replace(
              queryParameters: {
                ...Uri.parse(
                  endpoint(_endpoints['bootstrap'] as String? ?? '/bootstrap'),
                ).queryParameters,
                'app_version': _appVersion,
                'install_id': '${record['install_id']}',
              },
            );
    final response = await _network.jsonResponse(url.toString());
    if (response['ok'] != true) {
      throw StateError(
        'Signed-session bootstrap returned HTTP ${response['status']}',
      );
    }
    final body = jsonDecode(response['body'] as String) as Map<String, Object?>;
    if (generation != _generation) {
      throw StateError('Session changed during authentication');
    }
    if (body['session_id'] != null &&
        body['session_secret'] != null &&
        body['expires_at'] != null) {
      _save({...record, ...body});
      pending = null;
      blocked = false;
      return true;
    }
    var authUrl = (body['auth_url'] ?? body['challenge_url']) as String?;
    var state = _randomToken(24);
    if (authUrl == null && body['challenge_id'] != null) {
      final callback = Uri.parse(_callbackUrl);
      final withState = callback.replace(
        queryParameters: {
          ...callback.queryParameters,
          'cb_version': 'v2grant',
          'state': state,
        },
      );
      final challenge = Uri.parse(
        endpoint(_endpoints['challenge'] as String? ?? '/challenge'),
      );
      authUrl = challenge
          .replace(
            queryParameters: {
              ...challenge.queryParameters,
              'id': '${body['challenge_id']}',
              'cb': withState.toString(),
            },
          )
          .toString();
    }
    if (authUrl == null) {
      throw StateError('Signed-session bootstrap gave no verification page');
    }
    var challenge = morneyeValidateUrl(authUrl, _network.permissions);
    final nested =
        challenge.queryParameters['cb'] ??
        challenge.queryParameters['callback_url'] ??
        challenge.queryParameters['redirect_uri'];
    final nestedState = nested == null
        ? null
        : Uri.tryParse(nested)?.queryParameters['state'];
    state = challenge.queryParameters['state'] ?? nestedState ?? state;
    if (challenge.queryParameters['state'] == null && nestedState == null) {
      challenge = challenge.replace(
        queryParameters: {...challenge.queryParameters, 'state': state},
      );
    }
    pending = MorneyePending(challenge.toString(), state, DateTime.now());
    return false;
  }

  /// Trades the [grant] a verification page returned for a session.
  Future<Map<String, Object?>> completeGrant([String? grant]) {
    final value = grant ?? pendingGrant;
    if (value == null) {
      return Future.error(StateError('No pending verification grant'));
    }
    return _exchange ??= _completeGrant(value)
        .whenComplete(() => _exchange = null);
  }

  Future<Map<String, Object?>> _completeGrant(String grant) async {
    final generation = _generation;
    final record = this.record();
    final response = await _network.jsonResponse(
      endpoint(_endpoints['exchange'] as String? ?? '/session/exchange'),
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'grant': grant,
        'install_id': record['install_id'],
        'app_version': _appVersion,
        'platform': _platform,
      }),
    );
    if (response['ok'] != true) {
      throw StateError('Session exchange returned HTTP ${response['status']}');
    }
    final body = jsonDecode(response['body'] as String) as Map<String, Object?>;
    if (body['session_id'] == null ||
        body['session_secret'] == null ||
        body['expires_at'] == null) {
      throw StateError('Session exchange omitted its session fields');
    }
    if (generation != _generation) {
      throw StateError('Session changed during authentication');
    }
    _save({
      ...record,
      'session_id': body['session_id'],
      'session_secret': body['session_secret'],
      'expires_at': body['expires_at'],
    });
    pending = null;
    pendingGrant = null;
    blocked = false;
    return {'success': true};
  }

  /// Handles the page's redirect to the callback URL (spotiflac://session-grant).
  Future<Map<String, Object?>> callback(String raw) {
    var url = Uri.parse(raw);
    final nested = url.queryParameters['cb'];
    if (nested != null) url = Uri.parse(nested);
    final expected = Uri.parse(_callbackUrl);
    final pending = this.pending;
    final state = url.queryParameters['state'];
    if (url.scheme != expected.scheme ||
        url.authority != expected.authority ||
        url.path != expected.path ||
        pending == null ||
        DateTime.now().difference(pending.createdAt) >
            const Duration(minutes: 3) ||
        state == null ||
        state != pending.state) {
      return Future.error(
        StateError('Invalid or expired verification callback'),
      );
    }
    pendingGrant = url.queryParameters['grant'] ?? url.queryParameters['code'];
    return completeGrant();
  }

  /// Whether [raw] is where the verification page hands back its grant.
  bool isCallback(String raw) {
    final url = Uri.tryParse(raw);
    if (url == null) return false;
    final target = url.queryParameters['cb'] != null
        ? Uri.tryParse(url.queryParameters['cb']!)
        : url;
    final expected = Uri.parse(_callbackUrl);
    return target != null &&
        target.scheme == expected.scheme &&
        target.authority == expected.authority &&
        target.path == expected.path;
  }

  Future<void> _refresh(Map<String, Object?> record) {
    final path = _endpoints['refresh'] as String?;
    final expires = DateTime.tryParse('${record['expires_at'] ?? ''}');
    if (path == null ||
        expires == null ||
        expires.difference(DateTime.now()) > const Duration(hours: 1)) {
      return Future.value();
    }
    return _refreshing ??= () async {
      final generation = _generation;
      final response = await _request(
        record,
        'POST',
        path,
        jsonEncode({'install_id': record['install_id']}),
        const {},
      );
      if (response['ok'] != true) return;
      final next =
          jsonDecode(response['body'] as String) as Map<String, Object?>;
      if (generation == _generation &&
          this.record()['session_id'] == record['session_id']) {
        _save({
          ...record,
          for (final key in const [
            'session_id',
            'session_secret',
            'expires_at',
          ])
            if (next[key] != null) key: next[key],
        });
      }
    }().whenComplete(() => _refreshing = null);
  }

  Future<Map<String, Object?>> _request(
    Map<String, Object?> record,
    String method,
    String path,
    String body,
    Map<String, String> headers,
  ) {
    final url = endpoint(path);
    return _network.jsonResponse(
      url,
      method: method.toUpperCase(),
      body: body,
      headers: {
        'Content-Type': 'application/json',
        ...headers,
        ...morneyeSignedHeaders(config, record, method, url, body),
      },
    );
  }

  /// A signed request for the add-on; asks for verification when needed.
  Future<Map<String, Object?>> signedFetch(
    String method,
    String path, [
    String body = '',
    Map<String, String> headers = const {},
    Future<void> Function(Duration)? sleep,
  ]) async {
    final wait = sleep ?? (Duration d) => Future<void>.delayed(d);
    try {
      var record = this.record();
      if (!usable(record) || blocked) {
        if (!await bootstrap()) return verification();
        record = this.record();
      }
      await _refresh(record).catchError((_) {});
      record = this.record();
      for (var attempt = 0; attempt < 3; attempt++) {
        final response = await _request(record, method, path, body, headers);
        Map<String, Object?> contract = {};
        try {
          final decoded = jsonDecode(response['body'] as String);
          if (decoded is Map<String, Object?>) contract = decoded;
        } catch (_) {}
        final code = '${contract['code'] ?? ''}'.toUpperCase();
        final status = response['status'];
        if (status == 503 &&
            contract['origin'] == 'provider' &&
            code == 'PROVIDER_UNAVAILABLE' &&
            contract['retryable'] == true &&
            contract['retry_mode'] == 'same_operation' &&
            attempt < 2) {
          final seconds =
              ((contract['retry_after_seconds'] as num?)?.toInt() ?? 1).clamp(
                1,
                120,
              );
          await wait(Duration(seconds: seconds));
          continue;
        }
        final reset =
            status == 401 &&
            contract['origin'] == 'gateway' &&
            code == 'SESSION_INVALID' &&
            contract['action'] == 'bootstrap_session';
        final verify =
            status == 428 &&
            contract['origin'] == 'gateway' &&
            code == 'VERIFY_REQUIRED' &&
            contract['action'] == 'verify';
        if ((reset || verify) && attempt < 1) {
          if (reset) {
            clear();
          } else {
            blocked = true;
          }
          if (!await bootstrap()) return verification();
          record = this.record();
          continue;
        }
        return morneyeSignedAddonResponse(response, contract);
      }
      return {'ok': false, 'error': 'Signed request failed'};
    } catch (error) {
      return {'ok': false, 'error': '$error'};
    }
  }
}
