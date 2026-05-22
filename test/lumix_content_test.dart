import 'package:flutter_test/flutter_test.dart';
import 'package:sciens_gimbal_controller/camera/lumix_content.dart';

void main() {
  group('lumix_content — SSDP & descriptor', () {
    test('extractSsdpLocation reads the LOCATION header', () {
      const reply = 'HTTP/1.1 200 OK\r\n'
          'CACHE-CONTROL: max-age=1800\r\n'
          'LOCATION: http://192.168.54.1:60606/Lumix/Server0/ddd\r\n'
          'ST: upnp:rootdevice\r\n\r\n';
      expect(extractSsdpLocation(reply),
          'http://192.168.54.1:60606/Lumix/Server0/ddd');
      expect(extractSsdpLocation('HTTP/1.1 200 OK\r\n\r\n'), isNull);
    });

    test('findContentDirectory locates the service (absolute URL)', () {
      const descriptor = '<?xml version="1.0"?><root>'
          '<device><serviceList>'
          '<service>'
          '<serviceType>urn:schemas-upnp-org:service:ConnectionManager:1'
          '</serviceType>'
          '<controlURL>http://192.168.54.1:60606/Server0/CM_control'
          '</controlURL>'
          '</service>'
          '<service>'
          '<serviceType>urn:schemas-upnp-org:service:ContentDirectory:1'
          '</serviceType>'
          '<controlURL>http://192.168.54.1:60606/Server0/CDS_control'
          '</controlURL>'
          '</service>'
          '</serviceList></device></root>';
      final cd = findContentDirectory(
          descriptor, 'http://192.168.54.1:60606/Lumix/Server0/ddd');
      expect(cd, isNotNull);
      expect(cd!.controlUrl,
          'http://192.168.54.1:60606/Server0/CDS_control');
      expect(cd.serviceType, contains('ContentDirectory'));
    });

    test('findContentDirectory resolves a relative controlURL', () {
      const descriptor = '<root><device><serviceList><service>'
          '<serviceType>urn:schemas-upnp-org:service:ContentDirectory:1'
          '</serviceType>'
          '<controlURL>/Server0/CDS_control</controlURL>'
          '</service></serviceList></device></root>';
      final cd = findContentDirectory(
          descriptor, 'http://192.168.54.1:60606/Lumix/Server0/ddd');
      expect(cd!.controlUrl,
          'http://192.168.54.1:60606/Server0/CDS_control');
    });
  });

  group('lumix_content — Browse', () {
    test('browseSoapEnvelope embeds the parameters', () {
      final soap = browseSoapEnvelope(
          'urn:schemas-upnp-org:service:ContentDirectory:1', '0', 10, 5);
      expect(soap, contains('<ObjectID>0</ObjectID>'));
      expect(soap, contains('<StartingIndex>10</StartingIndex>'));
      expect(soap, contains('<RequestedCount>5</RequestedCount>'));
      expect(soap, contains('BrowseDirectChildren'));
    });

    test('parseBrowseResult extracts TotalMatches and the res URLs', () {
      const soap =
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
          '<s:Body>'
          '<u:BrowseResponse '
          'xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">'
          '<Result>'
          '&lt;DIDL-Lite&gt;'
          '&lt;item id=&quot;01020094&quot; parentID=&quot;0&quot;&gt;'
          '&lt;res protocolInfo=&quot;http-get:*:image/jpeg:'
          'DLNA.ORG_PN=JPEG_LRG&quot;&gt;'
          'http://192.168.54.1:50001/DO01020094.JPG&lt;/res&gt;'
          '&lt;res protocolInfo=&quot;http-get:*:image/jpeg:'
          'DLNA.ORG_PN=JPEG_SM&quot;&gt;'
          'http://192.168.54.1:50001/DS01020094.JPG&lt;/res&gt;'
          '&lt;res protocolInfo=&quot;http-get:*:image/jpeg:'
          'DLNA.ORG_PN=JPEG_TN&quot;&gt;'
          'http://192.168.54.1:50001/DT01020094.JPG&lt;/res&gt;'
          '&lt;/item&gt;'
          '&lt;/DIDL-Lite&gt;'
          '</Result>'
          '<TotalMatches>158</TotalMatches>'
          '<NumberReturned>1</NumberReturned>'
          '</u:BrowseResponse></s:Body></s:Envelope>';
      final r = parseBrowseResult(soap);
      expect(r.totalMatches, 158);
      expect(r.items.length, 1);
      final item = r.items.single;
      expect(item.id, '01020094');
      expect(item.mediumUrl, 'http://192.168.54.1:50001/DS01020094.JPG');
      expect(item.fullUrl, 'http://192.168.54.1:50001/DO01020094.JPG');
    });

    test('parseBrowseResult tolerates a malformed response', () {
      final r = parseBrowseResult('not xml at all');
      expect(r.totalMatches, 0);
      expect(r.items, isEmpty);
    });
  });
}
