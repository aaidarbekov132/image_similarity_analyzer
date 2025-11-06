import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'image_similarity_analyzer_platform_interface.dart';

/// An implementation of [ImageSimilarityAnalyzerPlatform] that uses method channels.
class MethodChannelImageSimilarityAnalyzer extends ImageSimilarityAnalyzerPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('image_similarity_analyzer');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
