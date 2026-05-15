import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sciens_gimbal_controller/camera/lumix_protocol.dart';

String _loadFixture(String name) =>
    File('test/fixtures/lumix/$name').readAsStringSync();

void main() {
  group('lumix_protocol — URL builders', () {
    const ip = '192.168.54.1';

    test('accCtrl URL contains pinned UUID + display name', () {
      final url = urlAccCtrl(ip);
      expect(url, contains('mode=accctrl'));
      expect(url, contains('type=req_acc'));
      expect(url, contains('value=$appUuid'));
      expect(url, contains('value2=Sciens'));
    });

    test('rec / play / state / capture URLs', () {
      expect(urlRecMode(ip), 'http://$ip/cam.cgi?mode=camcmd&value=recmode');
      expect(urlPlayMode(ip), 'http://$ip/cam.cgi?mode=camcmd&value=playmode');
      expect(urlGetState(ip), 'http://$ip/cam.cgi?mode=getstate');
      expect(urlCapture(ip), 'http://$ip/cam.cgi?mode=camcmd&value=capture');
      expect(urlCaptureCancel(ip),
          'http://$ip/cam.cgi?mode=camcmd&value=capture_cancel');
    });

    test('getInfoAllMenu', () {
      expect(urlGetInfoAllMenu(ip),
          'http://$ip/cam.cgi?mode=getinfo&type=allmenu');
    });

    test('getSetting / setSetting URL-encodes the value', () {
      expect(urlGetSetting(ip, 'shtrspeed'),
          'http://$ip/cam.cgi?mode=getsetting&type=shtrspeed');
      // Slashes in the shutter wire value must be percent-encoded.
      final set = urlSetSetting(ip, 'shtrspeed', '3328/256');
      expect(set, contains('mode=setsetting'));
      expect(set, contains('type=shtrspeed'));
      expect(set, contains('value=3328%2F256'));
    });

    test('startStream embeds the UDP port', () {
      expect(urlStartStream(ip, 49199),
          'http://$ip/cam.cgi?mode=startstream&value=49199');
      expect(urlStopStream(ip), 'http://$ip/cam.cgi?mode=stopstream');
    });
  });

  group('lumix_protocol — shutter encoding', () {
    test('Bulb sentinel decodes to infinity', () {
      expect(shutterWireToSeconds('256/256'), double.infinity);
      expect(shutterSecondsToLabel(double.infinity), 'B');
    });

    test('1 s = 0/256', () {
      final s = shutterWireToSeconds('0/256');
      expect(s, isNotNull);
      expect((s! - 1.0).abs() < 1e-9, true);
      expect(shutterSecondsToLabel(s), '1');
    });

    test('1/8000 s ≈ 3328/256', () {
      final s = shutterWireToSeconds('3328/256');
      expect(s, isNotNull);
      // 2^(-3328/256) = 2^-13 = 1/8192 ≈ 1.22e-4. Map to "1/8192".
      // libgphoto2's table says this slot is "1/8000" (camera-display
      // truncation). Our helper does the math, not the label-mapping
      // — so we check the round-tripped denominator falls in the
      // 1/8000-ish neighbourhood.
      expect(s! < 1.0 / 4000, true);
      expect(s > 1.0 / 16000, true);
    });

    test('1/4000 s ≈ 3072/256', () {
      final s = shutterWireToSeconds('3072/256')!;
      expect(s < 1.0 / 2000, true);
      expect(s > 1.0 / 8000, true);
    });

    test('long exposure: negative numerator → > 1 s', () {
      // -2048/256 = 2^8 = 256 s — well past 1 s.
      final s = shutterWireToSeconds('-2048/256')!;
      expect(s > 1.0, true);
    });

    test('garbage input returns null', () {
      expect(shutterWireToSeconds('not a shutter value'), null);
      expect(shutterWireToSeconds('3328'), null);
      expect(shutterWireToSeconds('3328/100'), null);
    });

    test('shutterSecondsToLabel rounds fractional denominators', () {
      // ~1/125 s.
      expect(shutterSecondsToLabel(1.0 / 125.0), '1/125');
      expect(shutterSecondsToLabel(1.0 / 60.0), '1/60');
      expect(shutterSecondsToLabel(30.0), '30');
    });
  });

  group('lumix_protocol — aperture readout', () {
    test('decodes wire format', () {
      // From the spec / lumixproto: f/1.7 = 392/256, f/2.2 = 598/256,
      // f/22 = 2304/256. f-number = 2^(num/512).
      final f17 = apertureWireToFNumber('392/256')!;
      final f22 = apertureWireToFNumber('598/256')!;
      final f22Big = apertureWireToFNumber('2304/256')!;
      expect((f17 - 1.7).abs() < 0.05, true);
      expect((f22 - 2.2).abs() < 0.05, true);
      expect((f22Big - 22.0).abs() < 1.0, true);
    });

    test('formats as f/N', () {
      expect(apertureFNumberToLabel(2.0), 'f/2');
      expect(apertureFNumberToLabel(2.8), 'f/2.8');
      expect(apertureFNumberToLabel(22.0), 'f/22');
    });

    test('garbage returns null', () {
      expect(apertureWireToFNumber('not_a_value'), null);
    });
  });

  group('lumix_protocol — optimistic capture timeout', () {
    test('Bulb / "B" → 60 s static', () {
      expect(optimisticCaptureTimeout('B'), const Duration(seconds: 60));
      expect(optimisticCaptureTimeout('Bulb'), const Duration(seconds: 60));
      expect(optimisticCaptureTimeout('bulb'), const Duration(seconds: 60));
    });

    test('"1/<N>" → ~10 s', () {
      // 1/125 s → 10 s + ~8 ms = 10008 ms.
      expect(optimisticCaptureTimeout('1/125'),
          const Duration(milliseconds: 10008));
      // 1/1 s → 10 s + 1 s = 11 s.
      expect(optimisticCaptureTimeout('1/1'),
          const Duration(milliseconds: 11000));
    });

    test('"<N>" or "<N>s" → 10 + N seconds', () {
      expect(optimisticCaptureTimeout('30'),
          const Duration(seconds: 40));
      expect(optimisticCaptureTimeout('30s'),
          const Duration(seconds: 40));
      expect(optimisticCaptureTimeout('1'),
          const Duration(seconds: 11));
    });

    test('garbage → 60 s fallback', () {
      expect(optimisticCaptureTimeout(''),
          const Duration(seconds: 60));
      expect(optimisticCaptureTimeout('garbage'),
          const Duration(seconds: 60));
      expect(optimisticCaptureTimeout('1/'),
          const Duration(seconds: 60));
    });
  });

  group('lumix_protocol — XML parsers (no-fixture subset)', () {
    test('isResultOk: well-formed "ok"', () {
      const body =
          '<?xml version="1.0"?><camrply><result>ok</result></camrply>';
      expect(isResultOk(body), true);
    });

    test('isResultOk: non-ok strings', () {
      const body =
          '<?xml version="1.0"?><camrply><result>err_busy</result></camrply>';
      expect(isResultOk(body), false);
      expect(resultText(body), 'err_busy');
    });

    test('isResultOk: handles malformed XML', () {
      expect(isResultOk('not xml'), false);
      // resultText surfaces the raw body for the UI to display.
      expect(resultText('not xml'), 'not xml');
    });

    test('isResultOk: plain-text "ok" response (no XML wrapping)', () {
      // Some Lumix bodies return just "ok" for accctrl / camcmd.
      expect(isResultOk('ok'), true);
      expect(isResultOk('OK'), true);
      expect(isResultOk('  ok  '), true);
      expect(isResultOk('ok\r\n'), true);
    });

    test('isResultOk: CSV with "ok_*" prefix (newer S5 firmware)', () {
      // Observed on the user's S5D via accctrl:
      //   ok_under_research_no_msg,S5D-FB94FA,remote_encrypted
      expect(
        isResultOk('ok_under_research_no_msg,S5D-FB94FA,remote_encrypted'),
        true,
      );
      expect(isResultOk('ok,foo,bar'), true);
      expect(isResultOk('OK_SOMETHING,DEVICE,FLAG'), true);
      // The CSV first field gates it: a non-ok prefix is still failure.
      expect(isResultOk('err_busy,...'), false);
      expect(isResultOk('nope_ok'), false);
    });

    test('isResultOk: empty body fails', () {
      expect(isResultOk(''), false);
      expect(isResultOk('   '), false);
      expect(resultText(''), '(empty response)');
    });

    test('resultText: truncates long bodies', () {
      final long = 'x' * 200;
      final result = resultText(long);
      expect(result.length, lessThan(long.length));
      expect(result, endsWith('…'));
    });

    test('isResultOk: case + whitespace tolerant', () {
      expect(isResultOk('<x><result>  OK  </result></x>'), true);
      expect(isResultOk('<x><result>Ok</result></x>'), true);
    });

    test('parseGetSetting reads the value from an XML attribute', () {
      // Schema confirmed against S5D fixture:
      //   <settingvalue shtrspeed="2048/256"></settingvalue>
      const body =
          '<?xml version="1.0"?><camrply><result>ok</result>'
          '<settingvalue shtrspeed="2048/256"></settingvalue>'
          '</camrply>';
      expect(parseGetSetting(body, 'shtrspeed'), '2048/256');
      expect(parseGetSetting(body, 'iso'), null);
    });

    test('isLumixDescriptor: Panasonic + DC- model', () {
      const desc = '''
<root>
  <device>
    <manufacturer>Panasonic</manufacturer>
    <modelName>DC-S5</modelName>
  </device>
</root>''';
      expect(isLumixDescriptor(desc), true);
    });

    test('isLumixDescriptor: Panasonic + DMC- model', () {
      const desc = '''
<root>
  <device>
    <manufacturer>Panasonic</manufacturer>
    <modelName>DMC-GH5</modelName>
  </device>
</root>''';
      expect(isLumixDescriptor(desc), true);
    });

    test('isLumixDescriptor: rejects other manufacturers', () {
      const desc = '''
<root>
  <device>
    <manufacturer>Sony</manufacturer>
    <modelName>DC-A7</modelName>
  </device>
</root>''';
      expect(isLumixDescriptor(desc), false);
    });

    test('isLumixDescriptor: rejects non-DC- / DMC- Panasonic model', () {
      const desc = '''
<root>
  <device>
    <manufacturer>Panasonic</manufacturer>
    <modelName>SC-HC1020</modelName>
  </device>
</root>''';
      expect(isLumixDescriptor(desc), false);
    });

    test('isLumixDescriptor: case-insensitive manufacturer', () {
      const desc = '''
<root>
  <device>
    <manufacturer>PANASONIC</manufacturer>
    <modelName>DC-S5</modelName>
  </device>
</root>''';
      expect(isLumixDescriptor(desc), true);
    });
  });

  // -------------------------------------------------------------------------
  // Fixture-driven tests. Real XML captured from a Panasonic S5D
  // (firmware VD4.30) at fixture-capture time. See
  // test/fixtures/lumix/.
  // -------------------------------------------------------------------------

  group('lumix_protocol — getsetting fixtures (S5D)', () {
    test('shtrspeed: attribute value is "2048/256"', () {
      final body = _loadFixture('getsetting_shtrspeed.xml');
      expect(isResultOk(body), true);
      expect(parseGetSetting(body, 'shtrspeed'), '2048/256');
      // Sanity: 2048/256 decodes to 1/256 s.
      final s = shutterWireToSeconds('2048/256')!;
      expect((s - 1 / 256).abs() < 1e-9, true);
    });

    test('iso: attribute value is "auto"', () {
      final body = _loadFixture('getsetting_iso.xml');
      expect(isResultOk(body), true);
      expect(parseGetSetting(body, 'iso'), 'auto');
    });

    test('focal: sentinel 32767/256 → apertureFromGetSetting returns null',
        () {
      final body = _loadFixture('getsetting_focal.xml');
      expect(isResultOk(body), true);
      expect(parseGetSetting(body, 'focal'), '32767/256');
      // The sentinel signals "no aperture data" — we must NOT
      // produce a number from it.
      expect(apertureFromGetSetting(body), null);
    });

    test('focal: real value → real f-number', () {
      const body = '<?xml version="1.0"?><camrply><result>ok</result>'
          '<settingvalue focal="598/256"></settingvalue></camrply>';
      // 598/256 → pow(2, 598/512) ≈ 2.2
      final f = apertureFromGetSetting(body)!;
      expect((f - 2.2).abs() < 0.05, true);
    });
  });

  group('lumix_protocol — getstate fixture (S5D)', () {
    test('parses cammode / battery / firmware / sdcard', () {
      final body = _loadFixture('getstate.xml');
      expect(isResultOk(body), true);
      final state = parseGetState(body)!;
      expect(state.cammode, 'play');
      expect(state.battery, '5/5');
      expect(state.firmwareVersion, 'VD4.30');
      expect(state.sdCardStatus, 'write_enable');
      expect(state.isPlayMode, true);
      expect(state.isRecMode, false);
    });

    test('synthetic rec-mode body flips isRecMode', () {
      const body = '<?xml version="1.0"?>'
          '<camrply><result>ok</result>'
          '<state><cammode>rec</cammode><batt>4/5</batt>'
          '<version>VD4.30</version>'
          '<sdcardstatus>write_enable</sdcardstatus></state></camrply>';
      final state = parseGetState(body)!;
      expect(state.isRecMode, true);
      expect(state.isPlayMode, false);
    });

    test('missing <state> → null', () {
      const body =
          '<?xml version="1.0"?><camrply><result>err</result></camrply>';
      expect(parseGetState(body), null);
    });
  });

  group('lumix_protocol — getinfo allmenu fixture (S5D)', () {
    test('parses ISO list, dedupes, includes "auto"', () {
      final body = _loadFixture('getinfo_allmenu.xml');
      final menu = parseAllMenu(body)!;
      expect(menu.isoValues, isNotEmpty);
      // "auto" must be the first ISO option offered.
      expect(menu.isoValues.first, 'auto');
      // Some standard ISO values must appear.
      expect(menu.isoValues, contains('100'));
      expect(menu.isoValues, contains('200'));
      expect(menu.isoValues, contains('800'));
      // Dedup: each value appears at most once.
      final unique = menu.isoValues.toSet();
      expect(unique.length, menu.isoValues.length);
    });

    test('ships hardcoded shutter list (allmenu does not enumerate)', () {
      final body = _loadFixture('getinfo_allmenu.xml');
      final menu = parseAllMenu(body)!;
      expect(menu.shutterValues, defaultShutterValues);
      // Bulb sentinel must be present.
      expect(menu.shutterValues, contains('256/256'));
    });
  });

  group('lumix_protocol — defaultShutterValues sanity', () {
    test('all entries decode to plausible seconds (Bulb → infinity)', () {
      for (final wire in defaultShutterValues) {
        final s = shutterWireToSeconds(wire);
        expect(s, isNotNull, reason: 'wire $wire failed to decode');
        if (wire == '256/256') {
          expect(s, double.infinity);
        } else {
          // 1/8192 s through ~30 s.
          expect(s! > 0, true);
          expect(s < 60, true);
        }
      }
    });
  });
}
