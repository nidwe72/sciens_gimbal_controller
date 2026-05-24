import 'package:audioplayers/audioplayers.dart';

/// Plays the PR 10 capture SFX:
///
/// - [playBeep] — short tone, one per countdown tick.
/// - [playShutter] — mechanical-shutter sample, played on capture
///   (delay = 0 immediately, delay > 0 at T = 0).
///
/// Mute gating is the *caller*'s responsibility — these methods
/// always play when invoked. `CameraConnection` consults its
/// `muted` ValueNotifier before calling.
abstract class CaptureSounds {
  Future<void> playBeep();
  Future<void> playShutter();
  Future<void> dispose();
}

/// No-op implementation for tests / environments where audio
/// playback is not available.
class NullCaptureSounds implements CaptureSounds {
  const NullCaptureSounds();

  @override
  Future<void> playBeep() async {}

  @override
  Future<void> playShutter() async {}

  @override
  Future<void> dispose() async {}
}

/// Production implementation using `audioplayers`. Two dedicated
/// AudioPlayer instances (beep, shutter) so the two clips never
/// have to interrupt each other.
///
/// Audio context is set globally on first play: Android usage type
/// = media (so the SFX route through STREAM_MUSIC and ignore the
/// device's ringer / silent mode — the in-app Mute checkbox is the
/// only audio gate). `AndroidAudioFocus.none` keeps us from fighting
/// other apps' audio focus for sub-second SFX.
class AudioPlayersCaptureSounds implements CaptureSounds {
  AudioPlayersCaptureSounds();

  AudioPlayer? _beepPlayer;
  AudioPlayer? _shutterPlayer;
  bool _contextInitialized = false;

  static final AudioContext _mediaContext = AudioContext(
    android: const AudioContextAndroid(
      isSpeakerphoneOn: false,
      stayAwake: false,
      contentType: AndroidContentType.music,
      usageType: AndroidUsageType.media,
      audioFocus: AndroidAudioFocus.none,
    ),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.ambient,
      options: const {AVAudioSessionOptions.mixWithOthers},
    ),
  );

  Future<void> _ensureContext() async {
    if (_contextInitialized) return;
    _contextInitialized = true;
    try {
      await AudioPlayer.global.setAudioContext(_mediaContext);
    } catch (_) {
      // Best-effort; if the platform rejects the config the players
      // still play with their defaults.
    }
  }

  Future<AudioPlayer> _ensure(AudioPlayer? existing) async {
    await _ensureContext();
    final p = existing ?? AudioPlayer()
      ..setReleaseMode(ReleaseMode.stop);
    return p;
  }

  @override
  Future<void> playBeep() async {
    try {
      _beepPlayer = await _ensure(_beepPlayer);
      await _beepPlayer!.play(AssetSource('sounds/beep.ogg'));
    } catch (_) {}
  }

  @override
  Future<void> playShutter() async {
    try {
      _shutterPlayer = await _ensure(_shutterPlayer);
      await _shutterPlayer!.play(AssetSource('sounds/shutter.mp3'));
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    final players = [_beepPlayer, _shutterPlayer];
    _beepPlayer = null;
    _shutterPlayer = null;
    for (final p in players) {
      try {
        await p?.dispose();
      } catch (_) {}
    }
  }
}
