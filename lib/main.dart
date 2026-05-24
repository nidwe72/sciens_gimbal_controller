import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/playground_screen.dart';

void main() {
  runApp(const ProviderScope(child: SciensGimbalControllerApp()));
}

class SciensGimbalControllerApp extends StatelessWidget {
  const SciensGimbalControllerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Panoramique (Sciens)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        // Green seed drives the brand accents (header, capture ring,
        // iris, buttons). Surface colours are forced to pure white
        // so the tab content areas don't pick up M3's default
        // tonal-surface green tint.
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32),
        ).copyWith(
          surface: Colors.white,
          surfaceBright: Colors.white,
          surfaceDim: Colors.white,
          surfaceContainerLowest: Colors.white,
          surfaceContainerLow: Colors.white,
          surfaceContainer: Colors.white,
          surfaceContainerHigh: Colors.white,
          surfaceContainerHighest: Colors.white,
          surfaceTint: Colors.transparent,
        ),
      ),
      home: const PlaygroundScreen(),
    );
  }
}
