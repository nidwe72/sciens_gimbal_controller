/// Pure helpers for the Panasonic Lumix WiFi protocol — URL builders,
/// shutter-speed encode/decode, app-identity constants, XML response
/// parsers, and the capture-button optimistic-disable timeout
/// calculation. No I/O lives here; this file is fully testable in
/// pure Dart.
///
/// See SPEC-flutter-app.md Phase 2 for the reverse-engineered
/// protocol reference. Endpoints follow the
/// `http://<ip>/cam.cgi?mode=<MODE>&...` pattern.
library;

import 'package:xml/xml.dart';

// ---------------------------------------------------------------------------
// App identity (pinned in spec). DO NOT regenerate without expecting
// every camera that's seen this app to re-prompt the user on first
// reconnect.
// ---------------------------------------------------------------------------

const String appUuid = '4D454900-1C3C-C912-CE00-FEE1FACE0001';
const String appDisplayName = 'Sciens';

// ---------------------------------------------------------------------------
// URL builders. All build a fully-formed `cam.cgi` URL against [ip]
// (no trailing slash). The HTTP port is the default 80.
// ---------------------------------------------------------------------------

String _base(String ip) => 'http://$ip/cam.cgi';

String urlAccCtrl(String ip) =>
    '${_base(ip)}?mode=accctrl&type=req_acc&value=$appUuid&value2=${Uri.encodeQueryComponent(appDisplayName)}';

String urlRecMode(String ip) => '${_base(ip)}?mode=camcmd&value=recmode';

String urlPlayMode(String ip) => '${_base(ip)}?mode=camcmd&value=playmode';

String urlGetState(String ip) => '${_base(ip)}?mode=getstate';

String urlGetInfoAllMenu(String ip) =>
    '${_base(ip)}?mode=getinfo&type=allmenu';

String urlGetSetting(String ip, String type) =>
    '${_base(ip)}?mode=getsetting&type=$type';

String urlSetSetting(String ip, String type, String value) =>
    '${_base(ip)}?mode=setsetting&type=$type&value=${Uri.encodeQueryComponent(value)}';

String urlCapture(String ip) => '${_base(ip)}?mode=camcmd&value=capture';

String urlCaptureCancel(String ip) =>
    '${_base(ip)}?mode=camcmd&value=capture_cancel';

String urlStartStream(String ip, int udpPort) =>
    '${_base(ip)}?mode=startstream&value=$udpPort';

String urlStopStream(String ip) => '${_base(ip)}?mode=stopstream';

/// Build an arbitrary `cam.cgi` URL from a query-parameter map. Used
/// by the diagnostics tool to probe endpoints the typed builders
/// above don't cover (`getinfo?type=curmenu`, lens info, …).
String urlRaw(String ip, Map<String, String> query) {
  final qs = query.entries
      .map((e) =>
          '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  return '${_base(ip)}?$qs';
}

// ---------------------------------------------------------------------------
// Shutter-speed encoding.
//
// Wire format: "<numerator>/256" plaintext. The displayed shutter time
// is approximately `pow(2, -numerator / 256)` seconds. Worked
// examples from libgphoto2's `shuttermap[]`:
//
//    3328/256  → 1/8000 s
//    3072/256  → 1/4000 s
//    0/256     → 1 s
//    256/256   → "B" (bulb sentinel)
//   negative   → long exposures
//
// We don't hardcode the table — the actual S5-supported list comes
// from `getinfo?type=allmenu` at connect time. This helper handles
// the math between wire value ↔ duration in seconds.
// ---------------------------------------------------------------------------

/// Sentinel wire value the protocol uses for Bulb.
const String shutterBulbWire = '256/256';

/// Parse a shutter wire value into a duration in seconds. Returns
/// `double.infinity` for the Bulb sentinel and `null` if [wire] isn't
/// a recognized `<int>/256` form.
double? shutterWireToSeconds(String wire) {
  final m = RegExp(r'^(-?\d+)/256$').firstMatch(wire.trim());
  if (m == null) return null;
  var numerator = int.parse(m.group(1)!);
  // The camera reports negative numerators as an unsigned int16 — a
  // 2 s exposure set as `-256/256` reads back as `65280/256`
  // (= -256 mod 65536). Fold the upper half of the uint16 range back
  // to negative so the signed form we send and the unsigned form the
  // body returns decode identically. See SPEC Pre-PR 5 — as built.
  if (numerator > 32767) numerator -= 65536;
  if (numerator == 256) return double.infinity; // Bulb
  // pow(2, -numerator/256): 2^x via exp(x * ln2) — avoids 'dart:math'.
  const ln2 = 0.6931471805599453;
  final x = -numerator / 256.0;
  return _exp(x * ln2);
}

/// Format a duration in seconds as the human label used in the
/// dropdown: "1/8000", "1/125", "1", "30", "B" (for infinity), etc.
String shutterSecondsToLabel(double seconds) {
  if (seconds == double.infinity) return 'B';
  if (seconds < 1.0) {
    final denom = (1.0 / seconds).round();
    return '1/$denom';
  }
  // Use one decimal for non-integer seconds, no decimal for integer.
  if (seconds == seconds.roundToDouble()) {
    return seconds.toInt().toString();
  }
  return seconds.toStringAsFixed(1);
}

/// Lightweight `exp(x)` via Taylor series, accurate enough for the
/// shutter range we work in (x ∈ ~[-10, +5]). Avoids importing
/// `dart:math` so this whole file stays portable and easy to test.
double _exp(double x) {
  // Use range reduction: e^x = e^(n + r) where n is integer and r is in [-0.5, 0.5).
  // Then e^n via repeated multiplication of e, e^r via Taylor.
  const e = 2.718281828459045;
  // Round to nearest integer.
  final n = x.round();
  final r = x - n;
  // e^n
  double en;
  if (n >= 0) {
    en = 1.0;
    for (int i = 0; i < n; i++) {
      en *= e;
    }
  } else {
    en = 1.0;
    for (int i = 0; i < -n; i++) {
      en /= e;
    }
  }
  // e^r via Taylor (degree 7 is overkill for |r| ≤ 0.5).
  double term = 1.0;
  double sum = 1.0;
  for (int k = 1; k <= 10; k++) {
    term *= r / k;
    sum += term;
  }
  return en * sum;
}

// ---------------------------------------------------------------------------
// Aperture readout decoding.
//
// Wire format: same "<numerator>/256". The displayed f-number is
// approximately `pow(2, numerator / 512)`.
// ---------------------------------------------------------------------------

double? apertureWireToFNumber(String wire) {
  final m = RegExp(r'^(-?\d+)/256$').firstMatch(wire.trim());
  if (m == null) return null;
  final num = int.parse(m.group(1)!);
  // pow(2, num/512)
  const ln2 = 0.6931471805599453;
  final x = num / 512.0;
  return _exp(x * ln2);
}

String apertureFNumberToLabel(double f) {
  // f/2.8 not f/2.83 — one decimal is plenty for camera-display style.
  if (f == f.roundToDouble()) return 'f/${f.toInt()}';
  return 'f/${f.toStringAsFixed(1)}';
}

// ---------------------------------------------------------------------------
// Capture-button optimistic-disable timeout.
//
// Computed from the *displayed label* of the currently-selected
// shutter dropdown. See SPEC-flutter-app.md Phase 2 "Capture button"
// for the table.
// ---------------------------------------------------------------------------

Duration optimisticCaptureTimeout(String shutterLabel) {
  final lbl = shutterLabel.trim();
  // Bulb: static 60 s ceiling.
  if (lbl == 'B' || lbl.toLowerCase() == 'bulb') {
    return const Duration(seconds: 60);
  }
  // "1/<N>" → 1/N seconds.
  final fraction = RegExp(r'^1/(\d+)$').firstMatch(lbl);
  if (fraction != null) {
    final n = int.tryParse(fraction.group(1)!);
    if (n != null && n > 0) {
      // 10 s + (1/n) s. The fraction is negligible at fast shutters
      // but we add it for correctness.
      return Duration(milliseconds: 10000 + (1000 / n).round());
    }
  }
  // "<N>" or "<N>s" → N seconds.
  final plain = RegExp(r'^(\d+(?:\.\d+)?)\s*s?$').firstMatch(lbl);
  if (plain != null) {
    final n = double.tryParse(plain.group(1)!);
    if (n != null && n >= 0) {
      return Duration(milliseconds: (10000 + n * 1000).round());
    }
  }
  // Parse failure → fall back to 60 s.
  return const Duration(seconds: 60);
}

// ---------------------------------------------------------------------------
// XML response parsing.
//
// Panasonic's `cam.cgi` returns small XML responses. Success is
// indicated by a `<result>ok</result>` element somewhere in the body;
// failures use other strings (`err_busy`, `err_param`, etc.). The
// detailed shape of `getstate`, `getsetting`, `getinfo?type=allmenu`,
// and the UPnP device descriptor is fixture-driven — we'll observe
// the real S5's responses and refine these parsers when the fixtures
// land. The function signatures below define the contract.
// ---------------------------------------------------------------------------

/// True iff the response body indicates success. Tolerant of the
/// three Panasonic response shapes seen in the wild:
///   1. **Plain text**: the body is just `ok` (case-insensitive,
///      possibly with surrounding whitespace). Observed on some
///      bodies for `accctrl`, `camcmd`, `setsetting`, etc.
///   2. **CSV with `ok_*` prefix**: e.g.,
///      `ok_under_research_no_msg,S5D-FB94FA,remote_encrypted`.
///      Observed on newer S5-family firmware (S5II/S5IIX/S5D and
///      recent S5). The first comma-separated field is the result
///      code; anything starting with `ok` is success.
///   3. **XML-wrapped**: the body parses as XML and contains a
///      `<result>` element whose inner text starts with `ok`.
///
/// Anything else (`err_busy`, HTML error page, empty body, …) is
/// failure — use [resultText] to get the actual content for the UI.
bool isResultOk(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return false;
  if (_isOkLiteral(trimmed)) return true;
  // XML-wrapped: look for <result>...</result>.
  try {
    final doc = XmlDocument.parse(body);
    final r = doc.findAllElements('result').firstOrNull;
    if (r == null) return false;
    return _isOkLiteral(r.innerText.trim());
  } catch (_) {
    return false;
  }
}

/// True iff [s] looks like a Panasonic "ok*" status — bare `ok`,
/// `ok_<code>` (the CSV format used by newer firmware), or `ok,<...>`
/// where extra fields follow. Case-insensitive.
bool _isOkLiteral(String s) {
  final lower = s.toLowerCase();
  if (lower == 'ok') return true;
  // First comma-separated field, then check prefix.
  final firstField = lower.split(',').first;
  return firstField == 'ok' || firstField.startsWith('ok_');
}

/// Human-readable text describing a non-`ok` response. Tolerant of
/// both plain-text and XML responses; on parse failure returns the
/// raw body (truncated) so the UI surfaces something actionable.
String resultText(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return '(empty response)';
  // If it doesn't look like XML, just return the (truncated) body.
  if (!trimmed.startsWith('<')) {
    return _truncate(trimmed, 120);
  }
  // XML: look for <result>...</result>.
  try {
    final doc = XmlDocument.parse(body);
    final r = doc.findAllElements('result').firstOrNull;
    if (r == null) {
      return 'no <result> element; body=${_truncate(trimmed, 120)}';
    }
    final inner = r.innerText.trim();
    return inner.isEmpty ? '(empty <result>)' : inner;
  } catch (_) {
    return 'unparseable XML; body=${_truncate(trimmed, 120)}';
  }
}

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

/// Parse a `getsetting&type=<T>` response. The Lumix S5D returns
/// the value as an **XML attribute** on the `<settingvalue>` element:
///
/// ```xml
/// <camrply>
///   <result>ok</result>
///   <settingvalue shtrspeed="2048/256"></settingvalue>
/// </camrply>
/// ```
///
/// Returns the attribute value, or null on parse failure / missing
/// attribute.
String? parseGetSetting(String body, String type) {
  try {
    final doc = XmlDocument.parse(body);
    final sv = doc.findAllElements('settingvalue').firstOrNull;
    return sv?.getAttribute(type);
  } catch (_) {
    return null;
  }
}

/// Sentinel `getsetting?type=focal` returns when no aperture data is
/// available (a manual-aperture lens, no lens, body in playback mode,
/// etc.). `32767` is `0x7FFF` — the max signed int16, a classic
/// "no value" marker.
const String apertureSentinelWire = '32767/256';

/// Decode a `<settingvalue focal="...">` attribute into an f-number.
/// Returns null when the camera reports the no-data sentinel.
double? apertureFromGetSetting(String body) {
  final wire = parseGetSetting(body, 'focal');
  if (wire == null) return null;
  if (wire == apertureSentinelWire) return null;
  return apertureWireToFNumber(wire);
}

/// A parsed `getstate` response. Used by PR 4's polling loop and the
/// connection summary.
///
/// Field set is the subset that's broadly useful — the camera reports
/// more (e.g. `<sd2_*>`, `<batt_grip>`, `<lens>`) but we only surface
/// what the UI actually shows. Add as needed.
class CameraState {
  CameraState({
    required this.cammode,
    required this.battery,
    required this.firmwareVersion,
    required this.sdCardStatus,
    required this.sdAccess,
    required this.remainCapacity,
  });

  /// Camera mode: usually `"rec"` (after `recmode`) or `"play"`.
  final String cammode;

  /// Battery indicator in "current/total" form, e.g. `"5/5"`.
  final String battery;

  /// Firmware version string, e.g. `"VD4.30"`.
  final String firmwareVersion;

  /// SD card status, e.g. `"write_enable"`, `"set"`, `"unset"`.
  final String sdCardStatus;

  /// True while the body is writing to the card (`<sd_access>on`) —
  /// the rec-mode "busy" signal (Pre-PR 5 finding).
  final bool sdAccess;

  /// Remaining stills the card can hold (`<remaincapacity>`), or null
  /// if absent. Decrements by one per saved shot — the Capture
  /// button's completion signal.
  final int? remainCapacity;

  bool get isRecMode => cammode == 'rec';
  bool get isPlayMode => cammode == 'play';
}

/// Parse a `getstate` response into a [CameraState]. Returns null if
/// the XML is malformed or doesn't contain a `<state>` block.
///
/// Schema (from the captured S5D fixture):
/// ```xml
/// <camrply>
///   <result>ok</result>
///   <state>
///     <batt>5/5</batt>
///     <cammode>play</cammode>
///     <sdcardstatus>write_enable</sdcardstatus>
///     <version>VD4.30</version>
///     ...
///   </state>
/// </camrply>
/// ```
CameraState? parseGetState(String body) {
  try {
    final doc = XmlDocument.parse(body);
    final state = doc.findAllElements('state').firstOrNull;
    if (state == null) return null;
    String inner(String tag) =>
        state.findElements(tag).firstOrNull?.innerText.trim() ?? '';
    return CameraState(
      cammode: inner('cammode'),
      battery: inner('batt'),
      firmwareVersion: inner('version'),
      sdCardStatus: inner('sdcardstatus'),
      sdAccess: inner('sd_access') == 'on',
      remainCapacity: int.tryParse(inner('remaincapacity')),
    );
  } catch (_) {
    return null;
  }
}

/// Extract the current shooting mode from a `getinfo?type=curmenu`
/// response — the `value` of the `menu_item_id_recmode` item
/// (`program_ae` / `aperture_ae` / `shutter_ae` / `manual_exposure` /
/// `ia` / `creative_movie` / `slow_quick` / `c1`…). Returns null if
/// the item is absent. A regex, not a full XML parse — `curmenu` is
/// ~45 KB and only one attribute is needed. The closing quote after
/// `recmode` keeps it from matching `menu_item_id_recmode_*` items.
String? parseRecmode(String curMenuBody) {
  final m = RegExp(r'id="menu_item_id_recmode"[^>]*?value="([^"]*)"')
      .firstMatch(curMenuBody);
  return m?.group(1);
}

/// The battery bar count from `getstate`'s `<batt>` value, which is in
/// `"N/M"` form (e.g. `"3/5"`). Returns N, or null if [batt] is null,
/// empty, or malformed. `<batt_per>` is always `-1` over WiFi, so the
/// bar count is the only level the camera gives.
int? batteryBars(String? batt) {
  if (batt == null) return null;
  final m = RegExp(r'^(\d+)/(\d+)$').firstMatch(batt.trim());
  return m == null ? null : int.parse(m.group(1)!);
}

/// Tags identifying a UPnP device descriptor as a Panasonic Lumix
/// camera. Used by the SSDP-discovery code in `lumix_camera.dart`.
bool isLumixDescriptor(String descriptorXml) {
  try {
    final doc = XmlDocument.parse(descriptorXml);
    final manuf = doc
        .findAllElements('manufacturer')
        .firstOrNull
        ?.innerText
        .trim()
        .toLowerCase();
    if (manuf != 'panasonic') return false;
    final model = doc
        .findAllElements('modelName')
        .firstOrNull
        ?.innerText
        .trim()
        .toUpperCase();
    if (model == null) {
      // Manufacturer is Panasonic — call it a match even without a model.
      return true;
    }
    return model.startsWith('DC-') || model.startsWith('DMC-');
  } catch (_) {
    return false;
  }
}

/// Allowed-values lists for shutter and ISO. ISO is extracted at
/// runtime from `getinfo?type=allmenu` (44+ entries on the S5D). The
/// stills shutter values are NOT enumerated in allmenu — only
/// `shtrspeed_angle` (video angle mode) appears — so we ship a
/// hardcoded standard list; the camera will reject anything it
/// doesn't accept and the UI will surface the error.
class AllMenu {
  AllMenu({
    required this.shutterValues,
    required this.isoValues,
    required this.exposureValues,
  });

  /// Wire values (`<n>/256` strings, plus `256/256` for Bulb).
  /// Sourced from [defaultShutterValues] — same list across bodies.
  final List<String> shutterValues;

  /// Wire values (`auto`, `100`, `200`, …) the body accepts for ISO.
  /// Extracted from allmenu, deduplicated (some bodies emit both a
  /// "100" and "L100" entry for the same wire value).
  final List<String> isoValues;

  /// EV-compensation wire values (`-5` … `5` in 1/3-stop steps, as
  /// `n` or `n/3`), extracted from allmenu and sorted ascending.
  final List<String> exposureValues;
}

/// Parse a `getinfo?type=allmenu` response and extract the ISO
/// allowed-value list. The schema uses `<item>` elements with
/// `cmd_mode="setsetting"` and `cmd_type="iso"`:
///
/// ```xml
/// <item id="menu_item_id_sensitivity_auto"
///       cmd_mode="setsetting"
///       cmd_type="iso"
///       cmd_value="auto" />
/// <item id="menu_item_id_sensitivity_100"
///       cmd_mode="setsetting"
///       cmd_type="iso"
///       cmd_value="100" />
/// ```
///
/// Shutter is paired with the hardcoded [defaultShutterValues] since
/// `cmd_type="shtrspeed"` is absent from allmenu on this body.
AllMenu? parseAllMenu(String body) {
  try {
    final doc = XmlDocument.parse(body);
    final iso = <String>[];
    final isoSeen = <String>{};
    final exposure = <String>[];
    final exposureSeen = <String>{};
    for (final item in doc.findAllElements('item')) {
      if (item.getAttribute('cmd_mode') != 'setsetting') continue;
      final v = item.getAttribute('cmd_value');
      if (v == null) continue;
      switch (item.getAttribute('cmd_type')) {
        case 'iso':
          if (isoSeen.add(v)) iso.add(v);
        case 'exposure':
          if (exposureSeen.add(v)) exposure.add(v);
      }
    }
    // EV values are numeric — sort ascending so the dropdown runs
    // -5 → +5 regardless of allmenu document order.
    exposure.sort((a, b) => (evThirds(a) ?? 0).compareTo(evThirds(b) ?? 0));
    return AllMenu(
      shutterValues: defaultShutterValues,
      isoValues: iso,
      exposureValues: exposure,
    );
  } catch (_) {
    return null;
  }
}

/// Standard shutter-speed wire values for setsetting `shtrspeed`.
/// Wire format: `<numerator>/256`, where displayed seconds ≈
/// `pow(2, -numerator/256)`. The Lumix protocol uses **exact
/// powers of 2** for the wire values; the camera body maps these to
/// the nearest standard 1/3-stop label for its on-screen display
/// (e.g. wire `2048/256` = 1/256 s, displayed as "1/250").
///
/// Order: fastest → slowest, then Bulb last. Used by the camera
/// tab's shutter dropdown when the body's allmenu doesn't enumerate
/// stills shutter values (currently always — newer S-series).
///
/// If the camera rejects any of these on `setsetting`, the UI shows
/// the error and the user picks a different one.
const List<String> defaultShutterValues = <String>[
  // Fast: 1/8192 down to 1/2.
  '3328/256', // 1/8192 (≈ "1/8000")
  '3072/256', // 1/4096 (≈ "1/4000")
  '2816/256', // 1/2048 (≈ "1/2000")
  '2560/256', // 1/1024 (≈ "1/1000")
  '2304/256', // 1/512  (≈ "1/500")
  '2048/256', // 1/256  (≈ "1/250")
  '1792/256', // 1/128  (≈ "1/125")
  '1536/256', // 1/64   (≈ "1/60")
  '1280/256', // 1/32   (≈ "1/30")
  '1024/256', // 1/16   (≈ "1/15")
  '768/256',  // 1/8
  '512/256',  // 1/4
  // 256/256 is the BULB sentinel — skip the 1/2 slot to avoid the
  // collision; the camera handles 1/2 via a non-power-of-2 wire
  // value we don't expose here.
  // Slow: 1 s and longer.
  '0/256',     // 1 s
  '-256/256',  // 2 s
  '-512/256',  // 4 s
  '-768/256',  // 8 s
  '-1024/256', // 16 s
  '-1280/256', // 30 s (approx)
  // Bulb last.
  '256/256',
];

/// Standard 1/3-stop aperture wire values for setsetting `focal`.
/// Wire `<numerator>/256`, displayed f-number ≈ `pow(2, numerator/512)`;
/// a 1/3 stop steps the numerator by 256/3. The mounted lens caps the
/// usable range — the camera `err_*`s any stop the lens can't reach,
/// which the camera tab surfaces.
///
/// Order: widest (f/1.4) → narrowest (f/22).
const List<String> defaultApertureValues = <String>[
  '256/256',  // f/1.4
  '341/256',  // f/1.6
  '427/256',  // f/1.8
  '512/256',  // f/2.0
  '597/256',  // f/2.2
  '683/256',  // f/2.5
  '768/256',  // f/2.8
  '853/256',  // f/3.2
  '939/256',  // f/3.5
  '1024/256', // f/4.0
  '1109/256', // f/4.5
  '1195/256', // f/5.0
  '1280/256', // f/5.6
  '1365/256', // f/6.3
  '1451/256', // f/7.1
  '1536/256', // f/8
  '1621/256', // f/9
  '1707/256', // f/10
  '1792/256', // f/11
  '1877/256', // f/13
  '1963/256', // f/14
  '2048/256', // f/16
  '2133/256', // f/18
  '2219/256', // f/20
  '2304/256', // f/22
];

/// The `defaultShutterValues` entry closest to a polled shutter wire,
/// compared by decoded duration — so the uint16 long-exposure form
/// and any body-set 1/3-stop value both resolve to the nearest
/// dropdown entry. Returns null if [polled] is null or undecodable.
String? nearestShutterWire(String? polled) {
  if (polled == null) return null;
  final target = shutterWireToSeconds(polled);
  if (target == null) return null;
  String? best;
  var bestDist = double.infinity;
  for (final wire in defaultShutterValues) {
    final s = shutterWireToSeconds(wire);
    if (s == null) continue;
    final double dist;
    if (s == target) {
      dist = 0;
    } else if (s.isInfinite || target.isInfinite) {
      dist = double.infinity;
    } else {
      dist = (s / target - 1).abs() + (target / s - 1).abs();
    }
    if (dist < bestDist) {
      bestDist = dist;
      best = wire;
    }
  }
  return best;
}

/// The `defaultApertureValues` entry closest to a polled `focal` wire,
/// compared by f-number. Returns null if [polled] is null, the
/// no-aperture sentinel, or undecodable.
String? nearestApertureWire(String? polled) {
  if (polled == null || polled == apertureSentinelWire) return null;
  final target = apertureWireToFNumber(polled);
  if (target == null) return null;
  String? best;
  var bestDist = double.infinity;
  for (final wire in defaultApertureValues) {
    final f = apertureWireToFNumber(wire);
    if (f == null) continue;
    final dist = (f - target).abs();
    if (dist < bestDist) {
      bestDist = dist;
      best = wire;
    }
  }
  return best;
}

// ---------------------------------------------------------------------------
// EV compensation. Wire values from allmenu `cmd_type="exposure"`: an
// integer `n` (whole EV) or `n/3` (1/3-stop). Range −5 … +5 EV.
// ---------------------------------------------------------------------------

/// An EV-compensation wire value as a numerator over 3 — `"-14/3"` →
/// −14, `"-4"` → −12, `"0"` → 0, `"5"` → 15. Null if [wire] is not an
/// integer or `n/3` form.
int? evThirds(String wire) {
  final w = wire.trim();
  final thirds = RegExp(r'^(-?\d+)/3$').firstMatch(w);
  if (thirds != null) return int.parse(thirds.group(1)!);
  final whole = RegExp(r'^(-?\d+)$').firstMatch(w);
  if (whole != null) return int.parse(whole.group(1)!) * 3;
  return null;
}

/// Human label for an EV-compensation wire value — conventional
/// 1/3-stop form: `"0"`, `"+5"`, `"-4⅔"`, `"+⅓"`. The whole/fraction
/// split is computed on the *absolute* numerator (Dart's `%` on a
/// negative misleads). Falls back to the raw [wire] if unparseable.
String evLabel(String wire) {
  final n = evThirds(wire);
  if (n == null) return wire;
  if (n == 0) return '0';
  final m = n.abs();
  final whole = m ~/ 3;
  final frac = switch (m % 3) {
    1 => '⅓',
    2 => '⅔',
    _ => '',
  };
  final wholeStr = (whole == 0 && frac.isNotEmpty) ? '' : '$whole';
  return '${n < 0 ? '-' : '+'}$wholeStr$frac';
}

/// The [options] entry whose EV value is closest to [polled], compared
/// via [evThirds] — so the integer and `n/3` wire forms match whichever
/// the camera echoes. Null if [polled] is null/undecodable or [options]
/// is empty.
String? nearestExposureWire(String? polled, List<String> options) {
  if (polled == null) return null;
  final target = evThirds(polled);
  if (target == null) return null;
  String? best;
  var bestDist = -1;
  for (final wire in options) {
    final n = evThirds(wire);
    if (n == null) continue;
    final dist = (n - target).abs();
    if (bestDist < 0 || dist < bestDist) {
      bestDist = dist;
      best = wire;
    }
  }
  return best;
}
