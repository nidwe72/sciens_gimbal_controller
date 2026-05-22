import 'dart:async';

import 'package:flutter/services.dart';

import 'camera_transport.dart';

/// Pure-Dart "Demo Lumix S5" — a [CameraTransport] that simulates a
/// camera with no network I/O. It synthesizes the same `cam.cgi` XML a
/// real S5D returns, so the `lumix_protocol.dart` parsers,
/// `CameraConnection` and `LumixContent` run unchanged against it.
///
/// Behaviour model: observable parity, not firmware fidelity (the same
/// principle as `DemoGimbalTransport`). Capture always shoots and the
/// camera is always in record mode — none of the real S5D's
/// record/playback quirks are re-enacted.
///
/// See SPEC-flutter-app.md "PR 9 — Demo Lumix S5".
class DemoLumixCamera implements CameraTransport {
  /// Connect-phase delay — long enough for the connecting screen's
  /// status strings to be visible as they flick past.
  static const _phaseDelay = Duration(milliseconds: 200);

  /// Per-request delay — a token "network" cost on poll / control
  /// calls so the UI behaves as it does against a real camera.
  static const _callDelay = Duration(milliseconds: 40);

  /// Fake camera IP. The demo builds no URLs — this is just the
  /// identifier surfaced as [cameraIp].
  static const _demoIp = '10.0.0.10';

  static const _okXml =
      '<?xml version="1.0"?><camrply><result>ok</result></camrply>';

  /// Bundled architectural JPEG — the demo's captured still and the
  /// full-resolution source for the full-screen viewer.
  static const _imageAsset = 'assets/demo/architecture.jpg';

  /// Live-preview frames — two downscaled variants of the same shot
  /// (the second has a subtle brightness/grain tweak), alternated at
  /// ~5 Hz to read as a live sensor feed rather than a frozen frame.
  static const _previewAssetA = 'assets/demo/preview_a.jpg';
  static const _previewAssetB = 'assets/demo/preview_b.jpg';

  /// Virtual UPnP MediaServer endpoints — kept mutually consistent so
  /// `LumixContent`'s SSDP -> descriptor -> Browse chain resolves.
  static const _descriptorUrl =
      'http://10.0.0.10:60606/Lumix/Server0/ddd';
  static const _controlUrl = 'http://10.0.0.10:60606/Server0/CDS_control';
  static const _contentDirType =
      'urn:schemas-upnp-org:service:ContentDirectory:1';
  static const _imageHost = 'http://10.0.0.10:50001';

  /// ISO values the virtual body reports via `getinfo?type=allmenu`.
  static const _isoValues = <String>[
    'auto', '100', '125', '160', '200', '250', '320', '400', '500',
    '640', '800', '1000', '1250', '1600', '2000', '2500', '3200',
    '4000', '5000', '6400', '8000', '10000', '12800', '16000',
    '20000', '25600',
  ];

  /// EV-compensation values (-3 .. +3 EV in 1/3 stops) the virtual
  /// body reports via allmenu — whole stops as integers, thirds as
  /// `n/3`, matching the mixed form a real body emits.
  static final List<String> _exposureValues = [
    for (int k = -9; k <= 9; k++) (k % 3 == 0) ? '${k ~/ 3}' : '$k/3',
  ];

  // --- Virtual camera body. Mutated by the "Virtual Lumix S5" tab.

  /// Shooting-mode dial as the `recmode` wire value: `program_ae` /
  /// `aperture_ae` / `shutter_ae` / `manual_exposure`.
  String dialMode = 'program_ae';

  /// Battery level, 0-5 bars.
  int batteryBars = 4;

  // --- Virtual exposure settings, updated by `setsetting`.

  String _shutterWire = '1792/256'; // ~1/125
  String _isoWire = '400';
  String _focalWire = '1024/256'; // f/4.0
  String _exposureWire = '0';

  /// Remaining still capacity — ample; one shot is subtracted per
  /// capture, which is the Capture button's completion signal.
  int _remainCapacity = 9999;

  /// Virtual SD card — ids of captured shots, in capture order.
  final List<String> _shots = [];
  int _shotCounter = 0;

  /// Asset bytes, cached after the first load.
  final Map<String, Uint8List> _assetCache = {};

  /// Live-preview pump (Step 5) — alternates [_previewAssetA] and
  /// [_previewAssetB] into [_previewFramesCtrl] at ~5 Hz.
  Timer? _previewTimer;

  String? _cameraIp;
  final _previewFramesCtrl = StreamController<Uint8List>.broadcast();

  Future<void> _delay([Duration d = _callDelay]) =>
      Future<void>.delayed(d);

  @override
  String? get cameraIp => _cameraIp;

  @override
  Future<void> bind() => _delay(_phaseDelay);

  @override
  Future<String?> discover() async {
    await _delay(_phaseDelay);
    return _cameraIp = _demoIp;
  }

  @override
  Future<bool> useManualIp(String ip) async {
    await _delay(_phaseDelay);
    _cameraIp = ip;
    return true;
  }

  @override
  Future<String> accCtrl() async {
    await _delay(_phaseDelay);
    // The real S5D answers accctrl with a CSV success line.
    return 'ok_under_research_no_msg,DEMO-S5D,remote_encrypted';
  }

  @override
  Future<String> recMode() async {
    await _delay(_phaseDelay);
    return _okXml;
  }

  @override
  Future<String> getState() async {
    await _delay();
    return '<?xml version="1.0"?><camrply><result>ok</result>'
        '<state><cammode>rec</cammode><batt>$batteryBars/5</batt>'
        '<version>DEMO</version><sdcardstatus>write_enable</sdcardstatus>'
        '<sd_access>off</sd_access>'
        '<remaincapacity>$_remainCapacity</remaincapacity>'
        '</state></camrply>';
  }

  @override
  Future<String> getInfoAllMenu() async {
    await _delay(_phaseDelay);
    final items = StringBuffer();
    for (final iso in _isoValues) {
      items.write('<item cmd_mode="setsetting" cmd_type="iso" '
          'cmd_value="$iso"/>');
    }
    for (final ev in _exposureValues) {
      items.write('<item cmd_mode="setsetting" cmd_type="exposure" '
          'cmd_value="$ev"/>');
    }
    return '<?xml version="1.0"?><camrply><result>ok</result>'
        '<menuinfo>$items</menuinfo></camrply>';
  }

  @override
  Future<String> getSetting(String type) async {
    await _delay();
    final value = switch (type) {
      'shtrspeed' => _shutterWire,
      'iso' => _isoWire,
      'focal' => _focalWire,
      'exposure' => _exposureWire,
      _ => '',
    };
    return '<?xml version="1.0"?><camrply><result>ok</result>'
        '<settingvalue $type="$value"></settingvalue></camrply>';
  }

  @override
  Future<String> setSetting(String type, String value) async {
    await _delay();
    switch (type) {
      case 'shtrspeed':
        _shutterWire = value;
      case 'iso':
        _isoWire = value;
      case 'focal':
        _focalWire = value;
      case 'exposure':
        _exposureWire = value;
      // device_name and anything else: accepted, no state change.
    }
    return _okXml;
  }

  @override
  Future<String> capture() async {
    await _delay();
    // A shot is saved: decrement capacity (the Capture button watches
    // this for completion) and append it to the virtual SD card.
    if (_remainCapacity > 0) _remainCapacity--;
    _shots.add('${++_shotCounter}');
    return _okXml;
  }

  @override
  Future<String> startStream(int udpPort) async {
    await _delay();
    final a = await _loadAsset(_previewAssetA);
    final b = await _loadAsset(_previewAssetB);
    _previewTimer?.cancel();
    var alt = false;
    _previewTimer =
        Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_previewFramesCtrl.isClosed) return;
      _previewFramesCtrl.add(alt ? b : a);
      alt = !alt;
    });
    return _okXml;
  }

  @override
  Future<String> stopStream() async {
    await _delay();
    _previewTimer?.cancel();
    _previewTimer = null;
    return _okXml;
  }

  @override
  Stream<Uint8List> get previewFrames => _previewFramesCtrl.stream;

  @override
  Future<String> rawGet(Map<String, String> query) async {
    await _delay();
    if (query['mode'] == 'getinfo' && query['type'] == 'curmenu') {
      // Only the recmode item is needed — parseRecmode reads it.
      return '<?xml version="1.0"?><camrply><result>ok</result>'
          '<menuinfo>'
          '<item id="menu_item_id_recmode" enable="yes" '
          'value="$dialMode" />'
          '</menuinfo></camrply>';
    }
    return _okXml;
  }

  @override
  Future<String> rawGetUrl(String url) async {
    await _delay();
    // The only URL LumixContent fetches here is the descriptor.
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<root xmlns="urn:schemas-upnp-org:device-1-0"><device>'
        '<deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>'
        '<friendlyName>Demo Lumix S5</friendlyName>'
        '<manufacturer>Panasonic</manufacturer>'
        '<modelName>DC-S5D</modelName>'
        '<serviceList><service>'
        '<serviceType>$_contentDirType</serviceType>'
        '<serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId>'
        '<controlURL>$_controlUrl</controlURL>'
        '</service></serviceList>'
        '</device></root>';
  }

  @override
  Future<Uint8List> rawGetBytes(String url, {Duration? timeout}) async {
    await _delay();
    return _loadAsset(_imageAsset);
  }

  @override
  Future<String> soapPost(
      String url, String soapAction, String body) async {
    await _delay();
    // Browse: return the requested window of the virtual SD card.
    final start = _intParam(body, 'StartingIndex');
    final count = _intParam(body, 'RequestedCount');
    final total = _shots.length;
    final from = start.clamp(0, total);
    final to = (count <= 0 ? total : start + count).clamp(from, total);
    final didl = StringBuffer(
        '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">');
    for (final id in _shots.sublist(from, to)) {
      didl.write('<item id="$id" parentID="0" restricted="1">'
          '<res protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG">'
          '$_imageHost/DO$id.JPG</res>'
          '<res protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_SM">'
          '$_imageHost/DS$id.JPG</res>'
          '</item>');
    }
    didl.write('</DIDL-Lite>');
    return '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
        '<s:Body><u:BrowseResponse xmlns:u="$_contentDirType">'
        '<Result>${_xmlEscape(didl.toString())}</Result>'
        '<NumberReturned>${to - from}</NumberReturned>'
        '<TotalMatches>$total</TotalMatches>'
        '<UpdateID>1</UpdateID>'
        '</u:BrowseResponse></s:Body></s:Envelope>';
  }

  @override
  Future<List<String>> ssdpProbe(
      {Duration window = const Duration(seconds: 3)}) async {
    await _delay();
    // One SSDP reply advertising the virtual MediaServer descriptor.
    return [
      'HTTP/1.1 200 OK\r\n'
      'CACHE-CONTROL: max-age=1800\r\n'
      'LOCATION: $_descriptorUrl\r\n'
      'SERVER: Demo/1.0 UPnP/1.0\r\n'
      'ST: urn:schemas-upnp-org:device:MediaServer:1\r\n'
      '\r\n',
    ];
  }

  @override
  Future<void> disconnect({bool streaming = false}) async {
    _previewTimer?.cancel();
    _previewTimer = null;
    _cameraIp = null;
    if (!_previewFramesCtrl.isClosed) await _previewFramesCtrl.close();
  }

  /// Load and cache a bundled asset's bytes.
  Future<Uint8List> _loadAsset(String path) async {
    final cached = _assetCache[path];
    if (cached != null) return cached;
    final data = await rootBundle.load(path);
    return _assetCache[path] =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// First `<tag>` integer in [xml], or 0 if absent.
  static int _intParam(String xml, String tag) {
    final m = RegExp('<$tag>(\\d+)</$tag>').firstMatch(xml);
    return m == null ? 0 : int.parse(m.group(1)!);
  }

  /// Escape a string for embedding as XML text — the DIDL-Lite sits
  /// inside `<Result>` escaped.
  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
