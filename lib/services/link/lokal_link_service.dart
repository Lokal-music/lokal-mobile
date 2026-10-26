import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/lokal_remote_state.dart';
import '../lokal_remote_service.dart';
import 'link_protocol.dart';

class LokalDiscoveredDesktop {
  const LokalDiscoveredDesktop({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
  });
  final String id, name, host;
  final int port;
  Uri get origin => Uri(scheme: 'http', host: host, port: port);
}

class LokalPairingLink {
  const LokalPairingLink(this.origin, this.desktopId, this.code);
  final Uri origin;
  final String desktopId, code;
  factory LokalPairingLink.parse(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri?.scheme != 'lokal' || uri?.host != 'pair')
      throw const FormatException('Scan a Lokal desktop pairing code.');
    final query = uri!.queryParameters;
    final host = query['host'] ?? '';
    final address = InternetAddress.tryParse(host);
    final port = int.tryParse(query['port'] ?? '') ?? 0;
    final code = query['code'] ?? '', id = query['id'] ?? '';
    if (address == null ||
        port < 1 ||
        port > 65535 ||
        !RegExp(r'^\d{6}$').hasMatch(code) ||
        !RegExp(r'^[a-zA-Z0-9_-]{8,128}$').hasMatch(id))
      throw const FormatException('This pairing code is incomplete.');
    return LokalPairingLink(
      Uri(scheme: 'http', host: host, port: port),
      id,
      code,
    );
  }
}

/// Paired LAN socket. Secrets stay in headers and encrypted storage, never URLs.
class LokalLinkService {
  static const channel = MethodChannel('lokal/desktop_link');
  final _messages = StreamController<LinkMessage>.broadcast();
  final _connections = StreamController<bool>.broadcast();
  final Map<String, Completer<LinkMessage>> _requests = {};
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  bool _closed = false;
  Stream<LinkMessage> get messages => _messages.stream;
  Stream<bool> get connections => _connections.stream;
  bool get connected => _socket?.readyState == WebSocket.open;

  Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('lokal.link.device_id');
    if (id == null) {
      id = linkUuid();
      await prefs.setString('lokal.link.device_id', id);
    }
    return id;
  }

  Future<void> _requestLocalNetwork() async {
    try {
      if (await channel.invokeMethod<bool>('requestLocalNetwork') == false)
        throw const LokalRemoteConfigurationException(
          'Allow local network access to connect to your desktop.',
        );
    } on MissingPluginException {
      /* Desktop and non-Android hosts. */
    }
  }

  Future<List<LokalDiscoveredDesktop>> discover() async {
    await _requestLocalNetwork();
    try {
      final values = await channel.invokeListMethod<dynamic>('discover');
      return [
        for (final raw in values ?? <dynamic>[])
          if (raw is Map && raw['host'] is String && raw['port'] is int)
            LokalDiscoveredDesktop(
              id: raw['id']?.toString() ?? '',
              name: raw['name']?.toString() ?? 'Lokal desktop',
              host: raw['host'] as String,
              port: raw['port'] as int,
            ),
      ];
    } on MissingPluginException {
      return [];
    } on PlatformException catch (error) {
      throw LokalRemoteConfigurationException(
        error.message ?? 'Local discovery could not start. Enter the desktop address or try again.',
      );
    }
  }

  Future<LokalRemoteCredentials> pair({
    required Uri origin,
    required String code,
    String? expectedDesktopId,
    String deviceName = 'Lokal phone',
  }) async {
    if (!RegExp(r'^\d{6}$').hasMatch(code))
      throw const LokalRemoteConfigurationException(
        'Enter the six-digit code shown on your desktop.',
      );
    await _requestLocalNetwork();
    final normalized = LokalRemoteService.normalizeOrigin(origin.toString());
    final response = await http
        .post(
          normalized.replace(path: '/api/remote/pair'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'code': code,
            'deviceName': deviceName,
            'deviceId': await deviceId(),
          }),
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) throw const LokalRemoteAuthException();
    final value = jsonDecode(response.body);
    if (value is! Map ||
        value['token'] is! String ||
        value['desktopId'] is! String ||
        (expectedDesktopId != null && value['desktopId'] != expectedDesktopId))
      throw const LokalRemoteProtocolException(
        'Pairing response did not match this desktop.',
      );
    return LokalRemoteCredentials(
      origin: normalized,
      remoteToken: value['token'] as String,
      desktopId: value['desktopId'] as String,
      desktopUserId: value['user'] is Map
          ? (value['user'] as Map)['id']?.toString()
          : null,
    );
  }

  Future<void> connect(LokalRemoteCredentials credentials) async {
    await _requestLocalNetwork();
    await disconnect();
    if (_closed) return;
    final uri = credentials.origin.replace(
      scheme: credentials.origin.scheme == 'https' ? 'wss' : 'ws',
      path: '/api/remote/ws',
    );
    final socket = await WebSocket.connect(
      uri.toString(),
      headers: {
        'x-remote-token': credentials.remoteToken,
        if (credentials.apiKey.isNotEmpty) 'x-api-key': credentials.apiKey,
      },
    ).timeout(const Duration(seconds: 8));
    if (_closed) {
      await socket.close();
      return;
    }
    _socket = socket;
    socket.pingInterval = const Duration(seconds: 25);
    _subscription = socket.listen(
      (raw) {
        if (raw is! String || raw.length > 1024 * 1024) return;
        try {
          final message = LinkMessage.decode(raw);
          final request = _requests.remove(message.id);
          if (request != null) {
            request.complete(message);
          }
          _messages.add(message);
        } on Object {
          unawaited(disconnect());
        }
      },
      onError: (Object error) {
        _lost();
      },
      onDone: _lost,
      cancelOnError: true,
    );
    _connections.add(true);
  }

  void _lost() {
    _socket = null;
    for (final request in _requests.values) {
      if (!request.isCompleted)
        request.completeError(
          const LokalRemoteNetworkException('Desktop link disconnected.'),
        );
    }
    _requests.clear();
    if (!_closed) _connections.add(false);
  }

  void send(String type, Map<String, dynamic> body, {String? id}) {
    if (!connected)
      throw const LokalRemoteNetworkException('Connect to your desktop first.');
    _socket!.add(LinkMessage.create(type, body, id: id).encode());
  }

  Future<LinkMessage> request(String type, Map<String, dynamic> body) async {
    final id = linkUuid(), completer = Completer<LinkMessage>();
    _requests[id] = completer;
    try {
      send(type, body, id: id);
      final reply = await completer.future.timeout(const Duration(seconds: 12));
      if (reply.type == 'ack' && reply.body['ok'] == false)
        throw LokalRemoteProtocolException(
          reply.body['error'] is String
              ? reply.body['error'] as String
              : 'Desktop command was rejected.',
        );
      return reply;
    } finally {
      _requests.remove(id);
    }
  }

  Future<void> disconnect() async {
    final socket = _socket;
    _socket = null;
    await _subscription?.cancel();
    _subscription = null;
    await socket?.close(WebSocketStatus.normalClosure);
    _lost();
  }

  Future<void> close() async {
    _closed = true;
    await disconnect();
    await _messages.close();
    await _connections.close();
  }
}
