import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/connect_screen.dart';

void main() {
  runApp(const ProviderScope(child: SciensGimbalControllerApp()));
}

class SciensGimbalControllerApp extends StatelessWidget {
  const SciensGimbalControllerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sciens Gimbal Controller',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF263238),
      ),
      home: const ConnectScreen(),
    );
  }
}
