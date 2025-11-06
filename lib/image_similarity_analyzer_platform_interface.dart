import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'image_similarity_analyzer_method_channel.dart';

abstract class ImageSimilarityAnalyzerPlatform extends PlatformInterface {
  /// Constructs a ImageSimilarityAnalyzerPlatform.
  ImageSimilarityAnalyzerPlatform() : super(token: _token);

  static final Object _token = Object();

  static ImageSimilarityAnalyzerPlatform _instance = MethodChannelImageSimilarityAnalyzer();

  /// The default instance of [ImageSimilarityAnalyzerPlatform] to use.
  ///
  /// Defaults to [MethodChannelImageSimilarityAnalyzer].
  static ImageSimilarityAnalyzerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [ImageSimilarityAnalyzerPlatform] when
  /// they register themselves.
  static set instance(ImageSimilarityAnalyzerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
