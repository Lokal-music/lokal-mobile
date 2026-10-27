import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A Morneye add-on's network access, as desktop's
/// electron/morneye/network.js: only the domains its manifest names, HTTPS
/// unless it allows HTTP, never a private address it didn't name, at most
/// five redirects, and its own cookies.

class MorneyeNetworkException implements Exception {
  const MorneyeNetworkException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Whether [address] is loopback, link-local, private or otherwise not on
/// the public internet.
bool morneyePrivateAddress(String address) {
  var value = address.toLowerCase();
  if (value.startsWith('::ffff:')) value = value.substring(7);
  final v4 = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$').firstMatch(value);
  if (v4 != null) {
    final a = int.parse(v4.group(1)!), b = int.parse(v4.group(2)!);
    return a == 0 ||
        a == 10 ||
        a == 127 ||
        a >= 224 ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 100 && b >= 64 && b <= 127);
  }
  return value == '::' ||
      value == '::1' ||
      RegExp(r'^(fc|fd|fe[89ab])').hasMatch(value);
}

/// Whether [host] is one of [domains]; `*.example.com` matches subdomains only.
bool morneyeDomainAllowed(String host, List<String> domains) => domains.any(
  (domain) => domain.startsWith('*.')
      ? host.endsWith(domain.substring(1)) && host != domain.substring(2)
      : host == domain.toLowerCase(),
);

/// The manifest's `permissions` as far as the network is concerned.
class MorneyePermissions {
  const MorneyePermissions({
    this.network = const [],
    this.storage = false,
    this.file = false,
    this.allowHttp = false,
  });

  factory MorneyePermissions.fromJson(Object? json) {
    final map = json is Map ? json : const {};
    return MorneyePermissions(
      network: [
        for (final domain
            in map['network'] is List ? map['network'] as List : const [])
          if (domain is String) domain,
      ],
      storage: map['storage'] == true,
      file: map['file'] == true,
      allowHttp: map['allowHttp'] == true,
    );
  }

  final List<String> network;
  final bool storage;
  final bool file;
  final bool allowHttp;

  Map<String, Object?> toJson() => {
    'network': network,
    'storage': storage,
    'file': file,
    if (allowHttp) 'allowHttp': true,
  };
}

/// Checks [raw] against [permissions]; the parsed URL when it may be fetched.
Uri morneyeValidateUrl(String raw, MorneyePermissions permissions) {
  final Uri url;
  try {
    url = Uri.parse(raw);
  } on FormatException {
    throw const MorneyeNetworkException('Invalid URL');
  }
  if (!url.hasScheme || url.host.isEmpty) {
    throw const MorneyeNetworkException('Invalid URL');
  }
  final host = url.host.toLowerCase();
  if (url.userInfo.isNotEmpty ||
      !morneyeDomainAllowed(host, permissions.network)) {
    throw MorneyeNetworkException('Network permission denied for $host');
  }
  if (url.scheme != 'https' &&
      !(url.scheme == 'http' && permissions.allowHttp)) {
    throw const MorneyeNetworkException('This addon requires HTTPS');
  }
  return url;
}

/// One stored cookie.
class MorneyeCookie {
  MorneyeCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.hostOnly,
    required this.path,
    required this.secure,
    this.expires,
  });

  final String name;
  final String value;
  final String domain;
  final bool hostOnly;
  final String path;
  final bool secure;
  final DateTime? expires;

  bool expired(DateTime now) => expires != null && !expires!.isAfter(now);

  bool matches(Uri url, DateTime now) {
    if (expired(now)) return false;
    final host = url.host.toLowerCase();
    final domainOk = hostOnly
        ? host == domain
        : host == domain || host.endsWith('.$domain');
    if (!domainOk) return false;
    if (secure && url.scheme != 'https') return false;
    final requestPath = url.path.isEmpty ? '/' : url.path;
    return requestPath == path ||
        (requestPath.startsWith(path) &&
            (path.endsWith('/') || requestPath[path.length] == '/'));
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'value': value,
    'domain': domain,
    'hostOnly': hostOnly,
    'path': path,
    'secure': secure,
    if (expires != null) 'expires': expires!.millisecondsSinceEpoch,
  };

  static MorneyeCookie? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'], value = json['value'], domain = json['domain'];
    if (name is! String || value is! String || domain is! String) return null;
    final expires = json['expires'];
    return MorneyeCookie(
      name: name,
      value: value,
      domain: domain,
      hostOnly: json['hostOnly'] != false,
      path: json['path'] is String ? json['path'] as String : '/',
      secure: json['secure'] == true,
      expires: expires is int
          ? DateTime.fromMillisecondsSinceEpoch(expires)
          : null,
    );
  }
}

/// The cookies one add-on has been given, as a browser would keep them.
class MorneyeCookieJar {
  MorneyeCookieJar([Iterable<MorneyeCookie> cookies = const []]) {
    for (final cookie in cookies) {
      _cookies[_key(cookie)] = cookie;
    }
  }

  final _cookies = <String, MorneyeCookie>{};

  static String _key(MorneyeCookie c) => '${c.domain};${c.path};${c.name}';

  bool get isEmpty => _cookies.isEmpty;

  void clear() => _cookies.clear();

  /// Stores one `Set-Cookie` [header] received from [url].
  void store(String header, Uri url, {DateTime? now}) {
    final Cookie parsed;
    try {
      parsed = Cookie.fromSetCookieValue(header);
    } catch (_) {
      return;
    }
    final at = now ?? DateTime.now();
    final host = url.host.toLowerCase();
    var domain = (parsed.domain ?? '').toLowerCase();
    if (domain.startsWith('.')) domain = domain.substring(1);
    final hostOnly = domain.isEmpty;
    if (hostOnly) {
      domain = host;
    } else if (host != domain && !host.endsWith('.$domain')) {
      return; // A site can't set cookies for another site.
    }
    var path = parsed.path ?? '';
    if (!path.startsWith('/')) {
      final requestPath = url.path.isEmpty ? '/' : url.path;
      final slash = requestPath.lastIndexOf('/');
      path = slash <= 0 ? '/' : requestPath.substring(0, slash);
    }
    DateTime? expires = parsed.expires;
    if (parsed.maxAge != null) {
      expires = at.add(Duration(seconds: parsed.maxAge!));
    }
    final cookie = MorneyeCookie(
      name: parsed.name,
      value: parsed.value,
      domain: domain,
      hostOnly: hostOnly,
      path: path,
      secure: parsed.secure,
      expires: expires,
    );
    if (cookie.expired(at)) {
      _cookies.remove(_key(cookie));
    } else {
      _cookies[_key(cookie)] = cookie;
    }
  }

  /// The `Cookie` header for [url], or empty.
  String header(Uri url, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final matching = _cookies.values.where((c) => c.matches(url, at)).toList()
      // Longer paths first, as browsers send them.
      ..sort((a, b) => b.path.length.compareTo(a.path.length));
    return matching.map((c) => '${c.name}=${c.value}').join('; ');
  }

  List<Map<String, Object?>> toJson() {
    final now = DateTime.now();
    return [
      for (final cookie in _cookies.values)
        if (!cookie.expired(now)) cookie.toJson(),
    ];
  }

  static MorneyeCookieJar fromJson(Object? json) => MorneyeCookieJar([
    for (final item in json is List ? json : const [])
      ?MorneyeCookie.fromJson(item),
  ]);
}

/// A streamed response; [close] it when done reading.
class MorneyeResponse {
  MorneyeResponse(this.url, this.status, this.headers, this._response);

  final Uri url;
  final int status;

  /// Lower-cased names; repeated headers joined with ", " (set-cookie aside).
  final Map<String, String> headers;
  final HttpClientResponse _response;

  Stream<List<int>> get body => _response;

  Future<void> close() async {
    try {
      await _response.detachSocket().then((socket) => socket.destroy());
    } catch (_) {
      // Already consumed or closed.
    }
  }
}

typedef MorneyeLookup = Future<List<InternetAddress>> Function(String host);

class MorneyeNetwork {
  MorneyeNetwork(
    this.permissions, {
    MorneyeCookieJar? cookies,
    HttpClient? client,
    MorneyeLookup? lookup,
    this.userAgent = 'Lokal',
    this.requestTimeout = const Duration(seconds: 30),
  }) : cookies = cookies ?? MorneyeCookieJar(),
       _client = client ?? (HttpClient()..autoUncompress = true),
       _lookup = lookup ?? InternetAddress.lookup;

  final MorneyePermissions permissions;
  MorneyeCookieJar cookies;
  final HttpClient _client;
  final MorneyeLookup _lookup;
  final String userAgent;
  /// Allows slow signed catalogue endpoints more time without slowing all add-ons.
  final Duration requestTimeout;

  /// The add-on's OAuth state (tokens, a pending login); kept with its cookies.
  Map<String, Object?> auth = {};

  /// Bumped on disconnect so a login still in flight doesn't write back.
  int generation = 0;

  /// Called when cookies or [auth] changed and should be saved.
  void Function()? persist;

  static const _redirects = {301, 302, 303, 307, 308};
  static final _dropped = RegExp(
    r'^(host|content-length|connection|transfer-encoding|proxy-authorization)$',
    caseSensitive: false,
  );
  static final _credentials = RegExp(
    r'^(authorization|cookie|x-.*(?:token|key|signature|session))$',
    caseSensitive: false,
  );

  Future<void> _checkAddress(Uri url, Duration timeout) async {
    final host = url.host;
    final literal = InternetAddress.tryParse(host);
    // Unlike openUrl/request.close, DNS had no deadline: a stalled Qobuz
    // hostname lookup could hold the foreground playback resolver forever.
    final addresses = literal != null ? [literal]
        : await _lookup(host).timeout(timeout);
    final explicitLocal =
        permissions.network.contains(host) &&
        (host == 'localhost' ||
            (literal != null && morneyePrivateAddress(literal.address)));
    if (addresses.isEmpty ||
        (!explicitLocal &&
            addresses.any((a) => morneyePrivateAddress(a.address)))) {
      throw const MorneyeNetworkException(
        'Addon request resolved to a private address without explicit permission',
      );
    }
  }

  /// Opens [raw]; follows redirects within the add-on's permissions.
  Future<MorneyeResponse> request(
    String raw, {
    String method = 'GET',
    String? body,
    Map<String, String> headers = const {},
    bool directMedia = false,
    Duration? timeout,
  }) async {
    final deadline = timeout ?? requestTimeout;
    var url = morneyeValidateUrl(raw, permissions);
    var sent = {
      for (final entry in headers.entries)
        if (!_dropped.hasMatch(entry.key)) entry.key: entry.value,
    };
    for (var hop = 0; hop <= 5; hop++) {
      await _checkAddress(url, deadline);
      final request = await _client.openUrl(method, url).timeout(deadline);
      request.followRedirects = false;
      final names = sent.keys.map((k) => k.toLowerCase()).toSet();
      if (!names.contains('user-agent')) {
        request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      }
      final cookie = directMedia ? '' : cookies.header(url);
      if (cookie.isNotEmpty && !names.contains('cookie')) {
        request.headers.set(HttpHeaders.cookieHeader, cookie);
      }
      sent.forEach((name, value) {
        try {
          request.headers.set(name, value, preserveHeaderCase: true);
        } catch (_) {
          // A header Dart refuses (invalid characters) is left out.
        }
      });
      if (body != null &&
          body.isNotEmpty &&
          method != 'GET' &&
          method != 'HEAD') {
        final bytes = utf8.encode(body);
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(deadline);
      if (!directMedia) {
        final setCookies = response.headers[HttpHeaders.setCookieHeader];
        if (setCookies != null && setCookies.isNotEmpty) {
          for (final header in setCookies) {
            cookies.store(header, url);
          }
          persist?.call();
        }
      }
      final headerMap = <String, String>{};
      response.headers.forEach((name, values) {
        headerMap[name.toLowerCase()] = values.join(', ');
      });
      final status = response.statusCode;
      final location = headerMap['location'];
      if (_redirects.contains(status) && location != null) {
        await response.drain<void>().catchError((_) {});
        if (directMedia) {
          throw const MorneyeNetworkException(
            'Direct-media downloads do not follow redirects',
          );
        }
        final next = morneyeValidateUrl(
          url.resolve(location).toString(),
          permissions,
        );
        if (next.origin != url.origin) {
          sent = {
            for (final entry in sent.entries)
              if (!_credentials.hasMatch(entry.key)) entry.key: entry.value,
          };
        }
        if (status == 303 ||
            ((status == 301 || status == 302) && method == 'POST')) {
          method = 'GET';
          body = null;
        }
        url = next;
        continue;
      }
      return MorneyeResponse(url, status, headerMap, response);
    }
    throw const MorneyeNetworkException('Too many addon redirects');
  }

  /// Fetches [raw] whole (up to 16 MB), shaped as the guest's `http` API
  /// expects; [asFetch] adds the body as base64 for `arrayBuffer()`.
  Future<Map<String, Object?>> jsonResponse(
    String raw, {
    String method = 'GET',
    String? body,
    Map<String, String> headers = const {},
    bool asFetch = false,
  }) async {
    final response = await request(
      raw,
      method: method,
      body: body,
      headers: headers,
    );
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.body.timeout(
      requestTimeout,
    )) {
      bytes.add(chunk);
      if (bytes.length > 16 * 1024 * 1024) {
        await response.close();
        throw const MorneyeNetworkException(
          'Addon network response exceeds 16 MB',
        );
      }
    }
    final data = bytes.takeBytes();
    final status = response.status;
    return {
      'statusCode': status,
      'status': status,
      'ok': status >= 200 && status < 300,
      'url': response.url.toString(),
      'headers': response.headers,
      'body': utf8.decode(data, allowMalformed: true),
      if (asFetch) 'binary': base64.encode(data),
    };
  }

  // Let active response finalizers return their connection before it closes.
  // Force-closing the pool races Dart's _HttpClient._returnConnection.
  void close() => _client.close();
}

/// Reads [stream] into memory, failing past [limit] bytes.
Future<Uint8List> morneyeReadAll(Stream<List<int>> stream, int limit) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    bytes.add(chunk);
    if (bytes.length > limit) {
      throw const MorneyeNetworkException('Response is too large');
    }
  }
  return bytes.takeBytes();
}
