# Changelog

## 0.0.2

- Added Android implementation of `scanLibraryForSimilar` (Kotlin,
  MediaStore-based). Photo library is scanned natively, thumbnails are
  hashed with dHash (9×8) and aHash (8×8), and groups of perceptually
  similar images are returned.
- Pairs are compared by Hamming distance over the 64-bit dHash and
  clustered with Union-Find, so bursts, edited copies, and resized
  variants are detected — not just bit-for-bit duplicates.
- Added `dHashDistanceThreshold` parameter on `scanLibraryForSimilar`
  (default `5`). Controls Android similarity strictness; lower is
  stricter.
- Added `progressStream` (`Stream<ScanProgress>`) and `ScanProgress`
  model exposing real-time scan progress (`processed`, `total`,
  `phase`). Emitted by Android only; on iOS the stream stays silent.
- On Android, `assetId` is returned as the bare MediaStore `_ID`
  (e.g. `"12345"`), not a `content://` URI.
- iOS implementation is unchanged. The legacy `aHashDistanceThreshold`
  parameter (default `0`) is still honored by iOS exactly as before.

## 0.0.1

- Initial release. iOS-only implementation of `scanLibraryForSimilar`
  using PhotoKit and Core Image (dHash + aHash perceptual hashing).
