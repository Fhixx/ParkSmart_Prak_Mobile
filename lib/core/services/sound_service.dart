import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'web_audio_stub.dart'
    if (dart.library.html) 'web_audio_web.dart';

class SoundService {
  static const MethodChannel _channel = MethodChannel('com.example.smart_parking/audio');

  /// Memutar file suara raw native (res/raw) seperti 'saya_akan_lawan' 1x saat animasi splash screen berjalan.
  static Future<void> playRawSound(String soundName) async {
    if (kIsWeb) {
      playWebAudio(soundName, loop: false);
      return;
    }
    try {
      await _channel.invokeMethod('playRawSound', {'sound': soundName});
    } catch (e) {
      debugPrint('[SoundService] Info playRawSound ($soundName): $e');
    }
  }

  /// Menghentikan pemutaran suara raw jika masih berjalan (misal saat splash screen selesai/dilewati).
  static Future<void> stopRawSound() async {
    if (kIsWeb) {
      stopAllWebAudio();
      return;
    }
    try {
      await _channel.invokeMethod('stopRawSound');
    } catch (e) {
      debugPrint('[SoundService] Info stopRawSound: $e');
    }
  }
}
