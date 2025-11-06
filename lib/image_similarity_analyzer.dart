
import 'image_similarity_analyzer_platform_interface.dart';

class ImageSimilarityAnalyzer {
  Future<String?> getPlatformVersion() {
    return ImageSimilarityAnalyzerPlatform.instance.getPlatformVersion();
  }
}
