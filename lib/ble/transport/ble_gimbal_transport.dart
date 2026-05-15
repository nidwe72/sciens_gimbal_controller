import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'gimbal_transport.dart';

/// SCORP "g6" profile (uuidType=1 in gimbal-properties-ble.xml).
/// Shared service for write and notify; see PROTOCOL-NOTES §2.
final scorpServiceUuid = Guid('0000ffff-0000-1000-8000-00805f9b34fb');
final scorpWriteCharUuid = Guid('0000ff01-0000-1000-8000-00805f9b34fb');
final scorpNotifyCharUuid = Guid('0000ff02-0000-1000-8000-00805f9b34fb');

/// Real-gimbal transport over BLE via `flutter_blue_plus`.
///
/// One instance per connect attempt: ConnectScreen builds it from the
/// tapped `BluetoothDevice` and passes it to `GimbalConnection.connect`.
/// After `disconnect()` the instance is single-use — build a fresh one
/// for the next connect.
///
/// `incoming` and `disconnected` are broadcast streams; subscribe to
/// `disconnected` BEFORE calling `openConnection()` to avoid losing an
/// early disconnect event.
class BleGimbalTransport implements GimbalTransport {
  BleGimbalTransport(this._device);

  final BluetoothDevice _device;

  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _notifyChar;
  StreamSubscription<BluetoothConnectionState>? _stateSub;
  StreamSubscription<List<int>>? _notifySub;
  final _incomingCtrl = StreamController<List<int>>.broadcast();
  final _disconnectedCtrl = StreamController<void>.broadcast();

  @override
  String get connectedName => _device.platformName.isNotEmpty
      ? _device.platformName
      : '(unnamed device)';

  @override
  String get connectedId => _device.remoteId.toString();

  @override
  Stream<List<int>> get incoming => _incomingCtrl.stream;

  @override
  Stream<void> get disconnected => _disconnectedCtrl.stream;

  @override
  Future<bool> openConnection() async {
    await _device.connect(
      license: License.free,
      timeout: const Duration(seconds: 15),
    );
    _stateSub = _device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected &&
          !_disconnectedCtrl.isClosed) {
        _disconnectedCtrl.add(null);
      }
    });
    return true;
  }

  @override
  Future<int?> prepareLink() async {
    // MTU failure is non-fatal — the connection is still usable at the
    // default MTU (23). Existing PROTOCOL-NOTES §4 notes the stock app
    // requests 512 and falls back gracefully. Mirror that.
    try {
      return await _device.requestMtu(512);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> discoverEndpoints() async {
    final services = await _device.discoverServices();

    BluetoothService? svc;
    for (final s in services) {
      if (s.serviceUuid == scorpServiceUuid) {
        svc = s;
        break;
      }
    }
    if (svc == null) return false;

    BluetoothCharacteristic? wc, nc;
    for (final c in svc.characteristics) {
      if (c.characteristicUuid == scorpWriteCharUuid) wc = c;
      if (c.characteristicUuid == scorpNotifyCharUuid) nc = c;
    }
    if (wc == null || nc == null) return false;

    _writeChar = wc;
    _notifyChar = nc;
    return true;
  }

  @override
  Future<bool> subscribeIncoming() async {
    final nc = _notifyChar;
    if (nc == null) return false;
    await nc.setNotifyValue(true);
    _notifySub = nc.onValueReceived.listen((data) {
      if (!_incomingCtrl.isClosed) _incomingCtrl.add(data);
    });
    return true;
  }

  @override
  Future<void> disconnect() async {
    await _notifySub?.cancel();
    _notifySub = null;
    await _stateSub?.cancel();
    _stateSub = null;
    try {
      await _device.disconnect();
    } catch (_) {
      // Already disconnected, or the OS rejected the call. Either way,
      // we've cleaned up our local state — nothing more to do.
    }
    if (!_incomingCtrl.isClosed) await _incomingCtrl.close();
    if (!_disconnectedCtrl.isClosed) await _disconnectedCtrl.close();
  }

  @override
  Future<void> sendFrame(List<int> bytes) async {
    final wc = _writeChar;
    if (wc == null) {
      throw StateError(
          'BleGimbalTransport.sendFrame: not connected (no write characteristic)');
    }
    final useNoResponse = wc.properties.writeWithoutResponse;
    await wc.write(bytes, withoutResponse: useNoResponse);
  }
}
