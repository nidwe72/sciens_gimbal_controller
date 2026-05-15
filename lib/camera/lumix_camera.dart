import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'lumix_protocol.dart';

/// Transport layer: speaks the `cam.cgi` HTTP protocol against a
/// Lumix camera on its WiFi access point. Owns the FIFO request queue
/// (serializes all HTTP calls so we don't depend on Panasonic's
/// undocumented reentrancy behaviour), the SSDP / manual-IP
/// discovery, the WifiNetworkChannel platform calls, and the polite-
/// goodbye disconnect sequence.
///
/// One instance per connect attempt. After [disconnect] this instance
/// is single-use — build a fresh one for the next connect (mirrors
/// the gimbal-side pattern in BleGimbalTransport).
///
/// See SPEC-flutter-app.md Phase 2.

class LumixCamera {
  LumixCamera({this.httpTimeout = const Duration(seconds: 5)});

  /// Per-request HTTP timeout (overridden for [accCtrl] which has a
  /// much longer body-side-prompt window).
  final Duration httpTimeout;

  static const _wifiChannel = MethodChannel(
    'at.sciens.gimbal_controller/wifi_network',
  );

  /// SSDP / manual-IP-probe discovery window.
  static const _discoveryWindow = Duration(seconds: 3);

  /// `accctrl` waits for the user to accept on the camera body —
  /// the camera will hold its prompt this long.
  static const _accCtrlTimeout = Duration(seconds: 60);

  /// Default Lumix IP on its own AP.
  static const String defaultCameraIp = '192.168.54.1';

  /// UPnP descriptor location convention.
  static const int upnpDescriptorPort = 60606;

  /// SSDP multicast group + port.
  static const String _ssdpAddress = '239.255.255.250';
  static const int _ssdpPort = 1900;

  final http.Client _httpClient = http.Client();
  final _HttpRequestQueue _queue = _HttpRequestQueue();

  /// Set after a successful [discover] (or after the manual fallback).
  String? _cameraIp;
  String? get cameraIp => _cameraIp;

  /// True once [bind] has been called (and not yet undone by [unbind]).
  bool _bound = false;

  // --- WifiNetworkChannel.

  /// Bind the process to a WiFi network and acquire the multicast
  /// lock for SSDP. Must be called before any HTTP / SSDP work. See
  /// SPEC Phase 2 "Connect-time and disconnect-time orderings".
  Future<void> bind() async {
    if (_bound) return;
    try {
      await _wifiChannel.invokeMethod<void>('bind');
      _bound = true;
    } on PlatformException catch (e) {
      throw LumixException('wifi_bind_failed: ${e.code}: ${e.message}');
    }
  }

  /// Restore default OS routing and release the multicast lock.
  /// Idempotent on the Java side.
  Future<void> unbind() async {
    if (!_bound) return;
    try {
      await _wifiChannel.invokeMethod<void>('unbind');
    } on PlatformException catch (_) {
      // Best effort — we're tearing down anyway.
    } finally {
      _bound = false;
    }
  }

  // --- Discovery.

  /// Find the camera IP. Runs SSDP and a direct probe of the default
  /// IP in parallel; whichever resolves first wins. Returns the IP,
  /// or null if both time out within [_discoveryWindow].
  ///
  /// Must be called *after* [bind] so the SSDP M-SEARCH and the
  /// probe both route over WiFi.
  Future<String?> discover() async {
    final ssdp = _discoverViaSsdp().catchError((_) => null);
    final probe = _probe(defaultCameraIp).then((ok) => ok ? defaultCameraIp : null);

    // Use a Completer + the two futures so we cancel the loser.
    final c = Completer<String?>();
    Timer? timeout;

    void finish(String? ip) {
      if (!c.isCompleted) {
        timeout?.cancel();
        c.complete(ip);
      }
    }

    ssdp.then((ip) {
      if (ip != null) finish(ip);
    });
    probe.then((ip) {
      if (ip != null) finish(ip);
    });

    // Hard window.
    timeout = Timer(_discoveryWindow, () => finish(null));

    final winner = await c.future;
    _cameraIp = winner;
    return winner;
  }

  /// Manually point the camera at a user-entered IP, bypassing
  /// discovery. Verifies the IP responds to `getstate` before
  /// accepting it.
  Future<bool> useManualIp(String ip) async {
    final ok = await _probe(ip);
    if (ok) _cameraIp = ip;
    return ok;
  }

  /// SSDP M-SEARCH; returns the IP of the first Lumix-shaped
  /// descriptor responder, or null on timeout.
  Future<String?> _discoverViaSsdp() async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.readEventsEnabled = true;
      socket.broadcastEnabled = true;

      final search = utf8.encode(
        'M-SEARCH * HTTP/1.1\r\n'
        'HOST: $_ssdpAddress:$_ssdpPort\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: ssdp:all\r\n'
        '\r\n',
      );
      socket.send(search, InternetAddress(_ssdpAddress), _ssdpPort);

      final completer = Completer<String?>();
      Timer? timeout;
      late StreamSubscription<RawSocketEvent> sub;

      sub = socket.listen((event) async {
        if (event != RawSocketEvent.read) return;
        final dg = socket!.receive();
        if (dg == null) return;
        final response = utf8.decode(dg.data, allowMalformed: true);
        final location = _extractLocation(response);
        if (location == null) return;

        // Fetch the descriptor and see if it's a Lumix.
        try {
          final r = await _httpClient
              .get(Uri.parse(location))
              .timeout(const Duration(seconds: 2));
          if (r.statusCode == 200 && isLumixDescriptor(_decodeBody(r))) {
            final ip = Uri.parse(location).host;
            if (!completer.isCompleted) {
              timeout?.cancel();
              completer.complete(ip);
              await sub.cancel();
            }
          }
        } catch (_) {
          // Skip this responder, keep listening.
        }
      });

      timeout = Timer(_discoveryWindow, () async {
        if (!completer.isCompleted) {
          completer.complete(null);
          await sub.cancel();
        }
      });

      return await completer.future;
    } finally {
      socket?.close();
    }
  }

  String? _extractLocation(String httpResponse) {
    for (final line in httpResponse.split('\r\n')) {
      final i = line.indexOf(':');
      if (i < 0) continue;
      final name = line.substring(0, i).trim().toLowerCase();
      if (name == 'location') {
        return line.substring(i + 1).trim();
      }
    }
    return null;
  }

  /// Direct probe of [ip]: does `getstate` return a Panasonic-shaped
  /// 200 response within [_discoveryWindow]?
  Future<bool> _probe(String ip) async {
    try {
      final r = await _httpClient
          .get(Uri.parse(urlGetState(ip)))
          .timeout(_discoveryWindow);
      if (r.statusCode != 200) return false;
      final body = _decodeBody(r);
      return isResultOk(body) ||
          // Some Lumix bodies don't include <result> on getstate; the
          // presence of a <state> or <camrply> tag is enough.
          body.contains('<state>') ||
          body.contains('<camrply>');
    } catch (_) {
      return false;
    }
  }

  // --- HTTP endpoints. All go through the FIFO queue.

  Future<String> accCtrl() => _request(
        urlAccCtrl(_requireIp()),
        timeout: _accCtrlTimeout,
      );

  Future<String> recMode() => _request(urlRecMode(_requireIp()));

  Future<String> playMode() => _request(urlPlayMode(_requireIp()));

  Future<String> getState() => _request(urlGetState(_requireIp()));

  Future<String> getInfoAllMenu() =>
      _request(urlGetInfoAllMenu(_requireIp()));

  Future<String> getSetting(String type) =>
      _request(urlGetSetting(_requireIp(), type));

  Future<String> setSetting(String type, String value) =>
      _request(urlSetSetting(_requireIp(), type, value));

  Future<String> capture() => _request(urlCapture(_requireIp()));

  Future<String> captureCancel() =>
      _request(urlCaptureCancel(_requireIp()));

  Future<String> startStream(int udpPort) =>
      _request(urlStartStream(_requireIp(), udpPort));

  Future<String> stopStream() => _request(urlStopStream(_requireIp()));

  String _requireIp() {
    final ip = _cameraIp;
    if (ip == null) {
      throw LumixException('not_connected: no camera IP set');
    }
    return ip;
  }

  Future<String> _request(String url, {Duration? timeout}) {
    return _queue.enqueue(() async {
      try {
        final r = await _httpClient
            .get(Uri.parse(url))
            .timeout(timeout ?? httpTimeout);
        if (r.statusCode != 200) {
          throw LumixException(
              'http_${r.statusCode}: ${r.reasonPhrase ?? "unknown"}');
        }
        return _decodeBody(r);
      } on TimeoutException {
        throw LumixException('http_timeout');
      } on SocketException catch (e) {
        throw LumixException('http_socket: ${e.message}');
      } on FormatException catch (e) {
        // Belt and suspenders: if Dart's http package or our own
        // decode somehow still throws on a malformed header, surface a
        // domain error instead of bubbling raw FormatException up to
        // the UI.
        throw LumixException('http_format: ${e.message}');
      }
    });
  }

  /// Decode an HTTP response body as UTF-8 from its raw bytes,
  /// bypassing `r.body`'s Content-Type parsing.
  ///
  /// Some Lumix endpoints return a malformed `Content-Type` header
  /// (e.g., literally `xml` instead of `text/xml`). Dart's
  /// `http` package's `Response.body` getter tries to parse the
  /// header to choose a charset, fails on the missing `/`, and
  /// throws `FormatException("invalid media type: expected '/'")`
  /// before we ever see the body. Using `bodyBytes` + manual UTF-8
  /// decode sidesteps the issue.
  static String _decodeBody(http.Response r) =>
      utf8.decode(r.bodyBytes, allowMalformed: true);

  // --- Polite goodbye + teardown.

  /// Disconnect sequence per SPEC Phase 2:
  ///   1. queue.cancel()
  ///   2. stopstream (if [streaming] is true)
  ///   3. playmode (polite goodbye)
  ///   4. unbind()
  ///   5. close HTTP client
  ///
  /// Steps 2 and 3 swallow errors — we're tearing down anyway.
  Future<void> disconnect({bool streaming = false}) async {
    // 1. Drop any in-flight + queued work.
    _queue.cancel();

    // 2 + 3. Polite goodbye (these need the WiFi binding so they must
    // run before unbind()). Best-effort.
    if (_cameraIp != null) {
      if (streaming) {
        try {
          await _httpClient
              .get(Uri.parse(urlStopStream(_cameraIp!)))
              .timeout(httpTimeout);
        } catch (_) {}
      }
      try {
        await _httpClient
            .get(Uri.parse(urlPlayMode(_cameraIp!)))
            .timeout(httpTimeout);
      } catch (_) {}
    }

    // 4. Restore default network routing.
    await unbind();

    // 5. Close transport.
    _httpClient.close();
    _cameraIp = null;
  }
}

/// Domain exception for Lumix transport failures. Wraps the various
/// underlying socket / HTTP / parse errors with a stable code string
/// the UI can show.
class LumixException implements Exception {
  LumixException(this.message);
  final String message;
  @override
  String toString() => 'LumixException: $message';
}

/// FIFO queue serializing HTTP requests. Supports cancellation.
class _HttpRequestQueue {
  final _pending = <_QueuedRequest<dynamic>>[];
  bool _draining = false;
  bool _cancelled = false;

  Future<T> enqueue<T>(Future<T> Function() body) {
    if (_cancelled) {
      return Future.error(LumixException('queue_cancelled'));
    }
    final completer = Completer<T>();
    _pending.add(_QueuedRequest<T>(body, completer));
    _drain();
    return completer.future;
  }

  /// Drop everything: fail in-flight + queued requests. The queue
  /// remains in a cancelled state and rejects new enqueues.
  void cancel() {
    _cancelled = true;
    final dropped = List.of(_pending);
    _pending.clear();
    for (final r in dropped) {
      if (!r.completer.isCompleted) {
        r.completer.completeError(LumixException('queue_cancelled'));
      }
    }
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_pending.isNotEmpty && !_cancelled) {
        final r = _pending.removeAt(0);
        try {
          final result = await r.body();
          if (!r.completer.isCompleted) r.completer.complete(result);
        } catch (e, st) {
          if (!r.completer.isCompleted) {
            r.completer.completeError(e, st);
          }
        }
      }
    } finally {
      _draining = false;
    }
  }
}

class _QueuedRequest<T> {
  _QueuedRequest(this.body, this.completer);
  final Future<T> Function() body;
  final Completer<T> completer;
}
