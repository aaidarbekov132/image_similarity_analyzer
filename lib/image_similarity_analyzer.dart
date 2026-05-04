import 'dart:async';
import 'package:flutter/services.dart';

class ScanProgress {
  final int processed;
  final int total;
  final String phase;

  const ScanProgress({
    required this.processed,
    required this.total,
    required this.phase,
  });

  double get fraction => total == 0 ? 0.0 : processed / total;

  @override
  String toString() =>
      'ScanProgress(processed: $processed, total: $total, phase: $phase)';
}

class ImageSimilarityAnalyzer {
  static const MethodChannel _channel = MethodChannel('image_similarity_analyzer');
  static const EventChannel _progressChannel =
      EventChannel('image_similarity_analyzer/progress');

  /// Stream of scan progress updates. Emitted only by the Android side;
  /// on iOS this stream stays silent.
  static Stream<ScanProgress> get progressStream =>
      _progressChannel.receiveBroadcastStream().map((event) {
        final map = (event as Map).cast<Object?, Object?>();
        return ScanProgress(
          processed: (map['processed'] as num?)?.toInt() ?? 0,
          total: (map['total'] as num?)?.toInt() ?? 0,
          phase: map['phase']?.toString() ?? '',
        );
      });

  /// Scans the photo library and returns groups of perceptually similar images.
  ///
  /// [dHashDistanceThreshold] — Hamming distance threshold over the 64-bit
  /// dHash, used by the Android implementation. Lower = stricter. Default 5
  /// finds bursts and edits while keeping false positives low.
  ///
  /// [aHashDistanceThreshold] — legacy iOS parameter (Hamming distance over
  /// aHash within an exact-dHash bucket). Kept for backward compatibility
  /// with the existing iOS implementation.
  static Future<List<List<String>>> scanLibraryForSimilar({
    int dHashDistanceThreshold = 5,
    int aHashDistanceThreshold = 0,
  }) async {
    try {
      final result = await _channel.invokeMethod<List>(
        'scanLibraryForSimilar',
        {
          'dHashDistanceThreshold': dHashDistanceThreshold,
          'aHashDistanceThreshold': aHashDistanceThreshold,
        },
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
