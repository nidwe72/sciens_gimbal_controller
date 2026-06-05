import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Full-screen, pinch-zoomable image viewer. Hides the system bars while
/// open so the image uses the whole screen in either orientation, and
/// shows a spinner while [loader] resolves.
///
/// Shared by the Capture tab (PR 8 — loads the full-res JPEG over the
/// network) and the Pano sub-tab (Phase 6 — loads the in-memory stitch
/// result). The [loader] returns the decoded image, or null / throws on
/// failure, in which case [failureMessage] is shown.
class FullScreenImage extends StatefulWidget {
  const FullScreenImage({
    super.key,
    required this.loader,
    this.failureMessage = 'Could not load the image.',
  });

  final Future<ui.Image?> Function() loader;
  final String failureMessage;

  @override
  State<FullScreenImage> createState() => _FullScreenImageState();
}

class _FullScreenImageState extends State<FullScreenImage> {
  ui.Image? _image;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _load();
  }

  Future<void> _load() async {
    ui.Image? image;
    try {
      image = await widget.loader();
    } catch (_) {
      image = null;
    }
    if (!mounted) {
      image?.dispose();
      return;
    }
    setState(() {
      _image = image;
      _failed = image == null;
    });
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final Widget content;
    if (image != null) {
      content = InteractiveViewer(
        maxScale: 6,
        child: RawImage(image: image, fit: BoxFit.contain),
      );
    } else if (_failed) {
      content = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            widget.failureMessage,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      );
    } else {
      content = const Center(child: CircularProgressIndicator());
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: content),
          Positioned(
            top: 0,
            left: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
