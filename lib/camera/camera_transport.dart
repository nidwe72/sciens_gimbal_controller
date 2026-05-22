import 'dart:typed_data';

/// Abstract transport for a Panasonic Lumix camera — the request /
/// response channel that `CameraConnection` and `LumixContent` talk
/// to.
///
/// Implementations:
///  - `LumixCamera`: the real camera over its WiFi access point —
///    `cam.cgi` HTTP, SOAP, the MJPEG UDP stream, SSDP discovery and
///    the `WifiNetworkChannel` platform calls.
///  - `DemoLumixCamera`: a pure-Dart simulator that synthesizes the
///    same wire-format responses with no real network I/O (see
///    SPEC-flutter-app.md "PR 9 — Demo Lumix S5").
///
/// Every method returns the raw wire payload — the `cam.cgi` XML, the
/// SOAP body, the image bytes — so the parsers in `lumix_protocol.dart`
/// and `lumix_content.dart` run unchanged against either transport.
abstract class CameraTransport {
  // --- Network binding + discovery.

  /// Bind the process to the camera's WiFi and acquire the multicast
  /// lock. Must precede any other call.
  Future<void> bind();

  /// Locate the camera. Returns its IP, or null if none was found.
  Future<String?> discover();

  /// Point the transport at a user-entered IP, verifying it responds.
  Future<bool> useManualIp(String ip);

  /// The IP in use, or null before discovery resolves.
  String? get cameraIp;

  // --- cam.cgi endpoints. Each returns the raw response body.

  Future<String> accCtrl();
  Future<String> recMode();
  Future<String> getState();
  Future<String> getInfoAllMenu();
  Future<String> getSetting(String type);
  Future<String> setSetting(String type, String value);
  Future<String> capture();
  Future<String> startStream(int udpPort);
  Future<String> stopStream();

  /// Decoded MJPEG live-preview frames (raw JPEG bytes). A broadcast
  /// stream: `startStream` begins delivery, `stopStream` ends it.
  Stream<Uint8List> get previewFrames;

  /// An arbitrary `cam.cgi` request — used for `curmenu` and by the
  /// diagnostics tool.
  Future<String> rawGet(Map<String, String> query);

  // --- UPnP / content retrieval.

  /// GET an arbitrary absolute URL (the UPnP descriptor, ...).
  Future<String> rawGetUrl(String url);

  /// GET an arbitrary URL as raw bytes (a captured JPEG). `timeout`
  /// overrides the transport's default per-request timeout.
  Future<Uint8List> rawGetBytes(String url, {Duration? timeout});

  /// POST a SOAP request — the ContentDirectory `Browse`.
  Future<String> soapPost(String url, String soapAction, String body);

  /// SSDP M-SEARCH; the raw response datagrams.
  Future<List<String>> ssdpProbe(
      {Duration window = const Duration(seconds: 3)});

  // --- Teardown.

  /// Polite-goodbye disconnect; releases all resources. Idempotent.
  Future<void> disconnect({bool streaming = false});
}
