import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sciens_gimbal_controller/ui/device_button.dart';

void main() {
  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: Center(child: child)));

  testWidgets('disconnected — outlined glyph, no spinner', (tester) async {
    await tester.pumpWidget(wrap(DeviceButton(
      icon: Icons.camera_alt,
      outlinedIcon: Icons.camera_alt_outlined,
      label: 'Camera',
      state: DeviceState.disconnected,
      onTap: () {},
    )));
    expect(find.byIcon(Icons.camera_alt_outlined), findsOneWidget);
    expect(find.byIcon(Icons.camera_alt), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Camera'), findsOneWidget);
  });

  testWidgets('connecting — outlined glyph + spinner', (tester) async {
    await tester.pumpWidget(wrap(DeviceButton(
      icon: Icons.camera_alt,
      outlinedIcon: Icons.camera_alt_outlined,
      label: 'Camera',
      state: DeviceState.connecting,
      onTap: () {},
    )));
    expect(find.byIcon(Icons.camera_alt_outlined), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('connected — filled glyph, no spinner', (tester) async {
    await tester.pumpWidget(wrap(DeviceButton(
      icon: Icons.camera_alt,
      outlinedIcon: Icons.camera_alt_outlined,
      label: 'Camera',
      state: DeviceState.connected,
      onTap: () {},
    )));
    expect(find.byIcon(Icons.camera_alt), findsOneWidget);
    expect(find.byIcon(Icons.camera_alt_outlined), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('tap invokes onTap', (tester) async {
    int taps = 0;
    await tester.pumpWidget(wrap(DeviceButton(
      icon: Icons.camera_alt,
      outlinedIcon: Icons.camera_alt_outlined,
      label: 'Camera',
      state: DeviceState.disconnected,
      onTap: () => taps++,
    )));
    await tester.tap(find.byType(DeviceButton));
    expect(taps, 1);
  });

  testWidgets('outlinedIcon omitted falls back to icon', (tester) async {
    await tester.pumpWidget(wrap(DeviceButton(
      icon: Icons.bluetooth,
      label: 'Test',
      state: DeviceState.disconnected,
      onTap: () {},
    )));
    expect(find.byIcon(Icons.bluetooth), findsOneWidget);
  });
}
