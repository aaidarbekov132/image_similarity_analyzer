import 'package:flutter_test/flutter_test.dart';
import 'package:image_similarity_analyzer/image_similarity_analyzer.dart';
import 'package:image_similarity_analyzer/image_similarity_analyzer_platform_interface.dart';
import 'package:image_similarity_analyzer/image_similarity_analyzer_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockImageSimilarityAnalyzerPlatform
    with MockPlatformInterfaceMixin
    implements ImageSimilarityAnalyzerPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final ImageSimilarityAnalyzerPlatform initialPlatform = ImageSimilarityAnalyzerPlatform.instance;

  test('$MethodChannelImageSimilarityAnalyzer is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelImageSimilarityAnalyzer>());
  });

  test('getPlatformVersion', () async {
    ImageSimilarityAnalyzer imageSimilarityAnalyzerPlugin = ImageSimilarityAnalyzer();
    MockImageSimilarityAnalyzerPlatform fakePlatform = MockImageSimilarityAnalyzerPlatform();
    ImageSimilarityAnalyzerPlatform.instance = fakePlatform;

    expect(await imageSimilarityAnalyzerPlugin.getPlatformVersion(), '42');
  });
}
