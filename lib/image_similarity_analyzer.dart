import 'dart:async';
import 'package:flutter/services.dart';

class ImageSimilarityAnalyzer {
  static const MethodChannel _channel = MethodChannel('image_similarity_analyzer');

  static Future<List<List<String>>> scanLibraryForSimilar({
    int aHashDistanceThreshold = 0,
  }) async {
    try {
      final result = await _channel.invokeMethod<List>(
        'scanLibraryForSimilar',
        {'aHashDistanceThreshold': aHashDistanceThreshold},
      );

      if (result == null) {
        return [];
      }

      return result.map((group) {
        if (group is List) {
          return group.map((id) => id.toString()).toList();
        }
        return <String>[];
      }).toList();
    } on PlatformException catch (e) {
      throw Exception('Failed to scan library: ${e.message}');
    }
  }
}