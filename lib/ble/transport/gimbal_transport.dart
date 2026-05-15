/// Abstract transport that ferries AK protocol bytes to/from a gimbal.
///
/// Implementations:
///  - [BleGimbalTransport]: talks to a real SCORP gimbal over BLE via
///    `flutter_blue_plus` (GATT connect → MTU request → service discovery
///    → notify subscribe).
///  - [DemoGimbalTransport]: pure-Dart simulator for running without
///    hardware (showcases, Android emulators that lack BLE, development
///    when the gimbal isn't in reach).
///
/// `GimbalConnection` drives the lifecycle phase-by-phase, emitting a
/// user-visible status string before each phase. The transport itself
/// owns no UI-facing strings — it is purely a byte channel + lifecycle
/// primitives. See SPEC-flutter-app.md "Phase 1 — Demo mode and 3D
/// visualization".
abstract class GimbalTransport {
  // --- Lifecycle. Each phase maps 1:1 to a status string emitted by
  //     GimbalConnection. Returning false aborts the connect sequence.

  /// Open the underlying connection.
  /// BLE: GATT connect.
  /// Demo: short artificial delay.
  Future<bool> openConnection();

  /// Negotiate link parameters. Returns the negotiated MTU on success,
  /// or null if MTU negotiation failed but the connection is still
  /// usable (returning null does NOT abort the connect sequence).
  /// BLE: requestMtu(512).
  /// Demo: returns 512 instantly.
  Future<int?> prepareLink();

  /// Discover the endpoints we'll be talking to.
  /// BLE: discoverServices() and find the write/notify characteristics.
  /// Demo: no-op.
  Future<bool> discoverEndpoints();

  /// Wire up the incoming byte stream.
  /// BLE: setNotifyValue(true) on the notify characteristic.
  /// Demo: start the simulator's ~10 Hz GIMBAL_STATE pump.
  Future<bool> subscribeIncoming();

  /// Close the connection and release resources. Idempotent.
  Future<void> disconnect();

  // --- Byte channel.

  /// Write one already-encoded AK frame to the gimbal. Throws on
  /// transport failure (BLE write error, transport already closed, …)
  /// so `GimbalConnection.send()` can log it with the existing
  /// LogEntry.error pattern. The transport itself emits no log entries
  /// and owns no UI-facing strings.
  Future<void> sendFrame(List<int> bytes);

  /// Bytes received from the gimbal. May arrive in pieces — the caller
  /// is responsible for AK frame reassembly via FrameStreamDecoder.
  Stream<List<int>> get incoming;

  // --- Connection state.

  /// Fires once when the connection drops, whether due to the gimbal
  /// going out of range, an underlying BLE error, or the user tapping
  /// Disconnect. GimbalConnection listens to this and runs its
  /// teardown.
  Stream<void> get disconnected;

  // --- Identity. Available from construction time — the BLE transport
  //     reads these off the `BluetoothDevice` it wraps; the demo
  //     hard-codes them. Surfaced via `GimbalConnection.connectedName`
  //     / `connectedId` so UI widgets don't need to know about
  //     `BluetoothDevice`.

  /// Human-readable device name.
  /// BLE: e.g. `FY_SCORP_C2_CD`. Demo: `Demo Gimbal`.
  String get connectedName;

  /// Device identifier.
  /// BLE: MAC address. Demo: `00:00:00:00:00:01`.
  String get connectedId;
}
