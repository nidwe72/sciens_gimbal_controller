import 'package:xml/xml.dart';

import 'lumix_camera.dart';

/// One image entry from the camera's UPnP ContentDirectory.
class ContentImage {
  ContentImage({required this.id, this.mediumUrl, this.fullUrl});

  /// DLNA object id (`01020094` ⇄ folder/file `102-0094`) — monotonic
  /// with capture order.
  final String id;

  /// `JPEG_SM` resource (~100 KB) for the inline pane, or null.
  final String? mediumUrl;

  /// `JPEG_LRG` resource (the full original) for the full-screen view.
  final String? fullUrl;
}

/// The `LOCATION` header value from an SSDP response, or null.
String? extractSsdpLocation(String ssdpResponse) {
  for (final line in ssdpResponse.split('\r\n')) {
    final i = line.indexOf(':');
    if (i < 0) continue;
    if (line.substring(0, i).trim().toLowerCase() == 'location') {
      return line.substring(i + 1).trim();
    }
  }
  return null;
}

/// Find the ContentDirectory service (control URL + serviceType) in a
/// UPnP device descriptor. [descUrl] resolves any relative controlURL.
({String controlUrl, String serviceType})? findContentDirectory(
    String descriptorXml, String descUrl) {
  try {
    final doc = XmlDocument.parse(descriptorXml);
    final base = doc.findAllElements('URLBase').firstOrNull?.innerText.trim();
    for (final svc in doc.findAllElements('service')) {
      final type =
          svc.findElements('serviceType').firstOrNull?.innerText.trim();
      if (type == null || !type.contains('ContentDirectory')) continue;
      final ctrl =
          svc.findElements('controlURL').firstOrNull?.innerText.trim();
      if (ctrl == null || ctrl.isEmpty) continue;
      final resolved =
          Uri.parse(base != null && base.isNotEmpty ? base : descUrl)
              .resolve(ctrl)
              .toString();
      return (controlUrl: resolved, serviceType: type);
    }
  } catch (_) {}
  return null;
}

/// A SOAP `Browse` envelope (`BrowseDirectChildren`).
String browseSoapEnvelope(
        String serviceType, String objectId, int startIndex, int count) =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
    's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
    '<s:Body>'
    '<u:Browse xmlns:u="$serviceType">'
    '<ObjectID>$objectId</ObjectID>'
    '<BrowseFlag>BrowseDirectChildren</BrowseFlag>'
    '<Filter>*</Filter>'
    '<StartingIndex>$startIndex</StartingIndex>'
    '<RequestedCount>$count</RequestedCount>'
    '<SortCriteria></SortCriteria>'
    '</u:Browse>'
    '</s:Body>'
    '</s:Envelope>';

/// Parse a SOAP `Browse` response into the total count and the image
/// items (with their `JPEG_SM` / `JPEG_LRG` resource URLs). The
/// `<Result>` element holds escaped DIDL-Lite.
({int totalMatches, List<ContentImage> items}) parseBrowseResult(
    String soapResponse) {
  try {
    final soap = XmlDocument.parse(soapResponse);
    final total = int.tryParse(
            soap.findAllElements('TotalMatches').firstOrNull?.innerText.trim() ??
                '') ??
        0;
    final result = soap.findAllElements('Result').firstOrNull?.innerText;
    if (result == null || result.isEmpty) {
      return (totalMatches: total, items: const []);
    }
    final didl = XmlDocument.parse(result);
    final items = <ContentImage>[];
    for (final item in didl.findAllElements('item')) {
      final id = item.getAttribute('id');
      if (id == null) continue;
      String? medium;
      String? full;
      for (final res in item.findElements('res')) {
        final pi = res.getAttribute('protocolInfo') ?? '';
        final url = res.innerText.trim();
        if (url.isEmpty) continue;
        if (pi.contains('JPEG_SM')) {
          medium = url;
        } else if (pi.contains('JPEG_LRG')) {
          full = url;
        }
      }
      items.add(ContentImage(id: id, mediumUrl: medium, fullUrl: full));
    }
    return (totalMatches: total, items: items);
  } catch (_) {
    return (totalMatches: 0, items: const []);
  }
}

/// Client for the camera's UPnP ContentDirectory — SSDP-discovers the
/// service (cached) and fetches the most-recent image entry.
class LumixContent {
  LumixContent(this._camera);

  final LumixCamera _camera;
  ({String controlUrl, String serviceType})? _cd;

  /// SSDP-discover the ContentDirectory control URL. Cached after the
  /// first success. Returns true once known.
  Future<bool> discover() async {
    if (_cd != null) return true;
    final List<String> replies;
    try {
      replies = await _camera.ssdpProbe();
    } catch (_) {
      return false;
    }
    for (final reply in replies) {
      final loc = extractSsdpLocation(reply);
      if (loc == null) continue;
      try {
        final cd = findContentDirectory(await _camera.rawGetUrl(loc), loc);
        if (cd != null) {
          _cd = cd;
          return true;
        }
      } catch (_) {
        // Try the next LOCATION.
      }
    }
    return false;
  }

  /// The most-recently-captured image, or null if none / discovery
  /// failed. Picks the highest-`id` item near the end of the list,
  /// rather than trusting the browse order.
  Future<ContentImage?> fetchLatest() async {
    if (_cd == null && !await discover()) return null;
    final cd = _cd!;
    Future<String> browse(int start, int count) => _camera.soapPost(
          cd.controlUrl,
          '${cd.serviceType}#Browse',
          browseSoapEnvelope(cd.serviceType, '0', start, count),
        );

    final first = parseBrowseResult(await browse(0, 1));
    if (first.totalMatches == 0) return null;
    final start = (first.totalMatches - 8).clamp(0, first.totalMatches);
    final tail = parseBrowseResult(await browse(start, 16));
    final items = tail.items.isNotEmpty ? tail.items : first.items;
    if (items.isEmpty) return null;
    items.sort((a, b) =>
        (int.tryParse(a.id) ?? 0).compareTo(int.tryParse(b.id) ?? 0));
    return items.last;
  }
}
