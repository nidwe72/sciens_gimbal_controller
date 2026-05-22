import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sciens_gimbal_controller/camera/camera_connection.dart';
import 'package:sciens_gimbal_controller/camera/lumix_camera.dart';

/// Canned camera backing a `MockClient`. Flags let a test flip it into
/// rejecting / failing states mid-session.
class _FakeCamera {
  bool failGetState = false;
  bool rejectAccctrl = false;
  bool rejectSetSetting = false;
  bool rejectCapture = false;

  String shutter = '1792/256';
  String iso = '400';
  String focal = '1024/256';

  static const _ok =
      '<?xml version="1.0"?><camrply><result>ok</result></camrply>';
  static const _err =
      '<?xml version="1.0"?><camrply><result>err_param</result></camrply>';
  static const _getstate = '<?xml version="1.0"?><camrply><result>ok</result>'
      '<state><cammode>rec</cammode><batt>3/5</batt><version>VD4.30</version>'
      '<sdcardstatus>write_enable</sdcardstatus><sd_access>off</sd_access>'
      '<remaincapacity>2438</remaincapacity></state></camrply>';
  static const _allmenu = '<?xml version="1.0"?><camrply><result>ok</result>'
      '<menuinfo>'
      '<item cmd_mode="setsetting" cmd_type="iso" cmd_value="auto"/>'
      '<item cmd_mode="setsetting" cmd_type="iso" cmd_value="400"/>'
      '</menuinfo></camrply>';

  String _settingValue(String type, String value) =>
      '<?xml version="1.0"?><camrply><result>ok</result>'
      '<settingvalue $type="$value"></settingvalue></camrply>';

  Future<http.Response> handle(http.Request req) async {
    final q = req.url.queryParameters;
    switch (q['mode']) {
      case 'getstate':
        return failGetState
            ? http.Response('', 500)
            : http.Response(_getstate, 200);
      case 'accctrl':
        return http.Response(rejectAccctrl ? _err : _ok, 200);
      case 'getinfo':
        return http.Response(_allmenu, 200);
      case 'getsetting':
        final type = q['type'] ?? '';
        final value = switch (type) {
          'shtrspeed' => shutter,
          'iso' => iso,
          'focal' => focal,
          _ => '0',
        };
        return http.Response(_settingValue(type, value), 200);
      case 'setsetting':
        return http.Response(rejectSetSetting ? _err : _ok, 200);
      case 'camcmd':
        final reject = q['value'] == 'capture' && rejectCapture;
        return http.Response(reject ? _err : _ok, 200);
      default:
        return http.Response(_ok, 200);
    }
  }
}

void main() {
  const wifiChannel =
      MethodChannel('at.sciens.gimbal_controller/wifi_network');

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // bind() / unbind() must succeed without a real platform.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wifiChannel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wifiChannel, null);
  });

  CameraConnection makeConn(_FakeCamera fake) => CameraConnection(
        cameraFactory: () =>
            LumixCamera(httpClient: MockClient(fake.handle)),
        pollInterval: const Duration(milliseconds: 10),
      );

  group('CameraConnection — connect lifecycle', () {
    test('manual-IP connect reaches Connected and caches caps', () async {
      final conn = makeConn(_FakeCamera());
      final result = await conn.connect(manualIp: '192.168.54.1');

      expect(result, isTrue);
      expect(conn.status, CameraStatus.connected);
      expect(conn.caps?.isoValues, contains('400'));

      await conn.disconnect();
      expect(conn.status, CameraStatus.disconnected);
    });

    test('a rejected accctrl fails the connect', () async {
      final conn = makeConn(_FakeCamera()..rejectAccctrl = true);
      final result = await conn.connect(manualIp: '192.168.54.1');

      expect(result, isFalse);
      expect(conn.status, CameraStatus.error);
      expect(conn.errorText, isNotNull);
    });
  });

  group('CameraConnection — polling', () {
    test('the poll populates shutter / ISO / aperture + remainCapacity',
        () async {
      final conn = makeConn(_FakeCamera());
      await conn.connect(manualIp: '192.168.54.1');
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(conn.shutterWire, '1792/256');
      expect(conn.isoWire, '400');
      expect(conn.focalWire, '1024/256');
      expect(conn.cameraState?.remainCapacity, 2438);

      await conn.disconnect();
    });

    test('three consecutive getstate failures drop the connection',
        () async {
      final fake = _FakeCamera();
      final conn = makeConn(fake);
      await conn.connect(manualIp: '192.168.54.1');
      expect(conn.status, CameraStatus.connected);

      fake.failGetState = true;
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(conn.status, CameraStatus.error);
      expect(conn.errorText, contains('lost'));
    });
  });

  group('CameraConnection — settings & capture', () {
    test('applySetting: null on ok, error string on err_*', () async {
      final fake = _FakeCamera();
      final conn = makeConn(fake);
      await conn.connect(manualIp: '192.168.54.1');

      expect(await conn.applySetting('iso', '400'), isNull);

      fake.rejectSetSetting = true;
      expect(await conn.applySetting('iso', '999999'), isNotNull);

      await conn.disconnect();
    });

    test('capture: null on ok, error string on err_*', () async {
      final fake = _FakeCamera();
      final conn = makeConn(fake);
      await conn.connect(manualIp: '192.168.54.1');

      expect(await conn.capture(), isNull);

      fake.rejectCapture = true;
      expect(await conn.capture(), isNotNull);

      await conn.disconnect();
    });
  });
}
