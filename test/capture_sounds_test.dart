import 'package:flutter_test/flutter_test.dart';
import 'package:sciens_gimbal_controller/camera/capture_sounds.dart';

void main() {
  test(
      'NullCaptureSounds — playBeep / playShutter / dispose no-op',
      () async {
    const sounds = NullCaptureSounds();
    await sounds.playBeep();
    await sounds.playShutter();
    await sounds.dispose();
    // Reaching here without exceptions is the test.
  });
}
