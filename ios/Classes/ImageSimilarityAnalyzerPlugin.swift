import Foundation
import Photos
import CoreImage
import Flutter
import UIKit

struct ImageFingerprint {
    let assetId: String
    let aHash: UInt64
}

@objc(ImageSimilarityAnalyzerPlugin)
public class ImageSimilarityAnalyzerPlugin: NSObject, FlutterPlugin {
    
    private var dHashLookupCache: [UInt64: [ImageFingerprint]] = [:]
    
    private let storageQueue = DispatchQueue(label: "storageAccess", attributes: .concurrent)
    
    private let ciContext = CIContext(options: nil)

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "image_similarity_analyzer", binaryMessenger: registrar.messenger())
        let instance = ImageSimilarityAnalyzerPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "scanLibraryForSimilar":
            let args = call.arguments as? [String: Any]
            let threshold = args?["aHashDistanceThreshold"] as? Int ?? 0
            
            DispatchQueue.global(qos: .userInitiated).async {
                self.scanLibraryForSimilar(aHashThreshold: UInt64(threshold)) { duplicateGroups in
                    DispatchQueue.main.async {
                        result(duplicateGroups)
                    }
                }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func scanLibraryForSimilar(aHashThreshold: UInt64, completion: @escaping ([[String]]) -> Void) {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized else {
                completion([])
                return
            }
            
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)
            
            self.storageQueue.async(flags: .barrier) {
                self.dHashLookupCache.removeAll()
            }
            
            let totalCount = fetchResult.count
            var processedCount = 0
            let syncQueue = DispatchQueue(label: "syncQueue")
            
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "fingerprintCalculation", attributes: .concurrent)
            
            let batchSize = 50
            var batchStart = 0
            
            func processBatch() {
                let batchEnd = min(batchStart + batchSize, totalCount)
                guard batchStart < batchEnd else {
                    group.notify(queue: .main) {
                        self.clusterSimilarImages(aHashThreshold: aHashThreshold, completion: completion)
                    }
                    return
                }

                for i in batchStart..<batchEnd {
                    let asset = fetchResult.object(at: i)
                    
                    group.enter()
                    queue.async {
                        self.computeImageFingerprints(for: asset) {
                            syncQueue.async {
                                processedCount += 1
                                if processedCount % 50 == 0 {
                                    
                                }
                            }
                            group.leave()
                        }
                    }
                }
                
                group.notify(queue: .main) {
                    batchStart += batchSize
                    if batchStart < totalCount {
                        processBatch()
                    } else {
                        self.clusterSimilarImages(aHashThreshold: aHashThreshold, completion: completion)
                    }
                }
            }
            
            processBatch()
        }
    }
    
    private func computeImageFingerprints(for asset: PHAsset, completion: @escaping () -> Void) {
        autoreleasepool {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .fastFormat
            options.isSynchronous = true
            options.resizeMode = .exact
            
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 64, height: 64),
                contentMode: .aspectFit,
                options: options
            ) { [weak self] image, info in
                guard let self = self, let image = image else {
                    completion()
                    return
                }
                
                autoreleasepool {
                    let dHash = self.computeDHash(from: image)
                    let aHash = self.computeAHash(from: image)
                    
                    let fingerprint = ImageFingerprint(assetId: asset.localIdentifier, aHash: aHash)
                    
                    self.storageQueue.async(flags: .barrier) {
                        if self.dHashLookupCache[dHash] == nil {
                            self.dHashLookupCache[dHash] = []
                        }
                        self.dHashLookupCache[dHash]?.append(fingerprint)
                        completion()
                    }
                }
            }
        }
    }
    
    private func clusterSimilarImages(aHashThreshold: UInt64, completion: @escaping ([[String]]) -> Void) {
        self.storageQueue.async { [weak self] in
            guard let self = self else {
                completion([])
                return
            }
            
            let localCache = self.dHashLookupCache
            
            var allDuplicateGroups: [[String]] = []
            var processedIdentifiers = Set<String>()
            
            for potentialGroup in localCache.values where potentialGroup.count > 1 {
                
                for i in 0..<potentialGroup.count {
                    let primaryFingerprint = potentialGroup[i]
                    
                    if processedIdentifiers.contains(primaryFingerprint.assetId) {
                        continue
                    }
                    
                    var currentGroup: [String] = [primaryFingerprint.assetId]
                    
                    for j in (i + 1)..<potentialGroup.count {
                        let secondaryFingerprint = potentialGroup[j]
                        
                        if processedIdentifiers.contains(secondaryFingerprint.assetId) {
                            continue
                        }
                        
                        let aDistance = self.computeHammingDistance(
                            between: primaryFingerprint.aHash,
                            and: secondaryFingerprint.aHash
                        )
                        
                        if aDistance <= aHashThreshold {
                            currentGroup.append(secondaryFingerprint.assetId)
                        }
                    }
                    
                    if currentGroup.count > 1 {
                        allDuplicateGroups.append(currentGroup)
                        processedIdentifiers.formUnion(currentGroup)
                    }
                }
            }
            
            DispatchQueue.main.async {
                completion(allDuplicateGroups)
            }
        }
    }
    
    private func computeAHash(from image: UIImage) -> UInt64 {
        guard let pixels = getGrayscalePixels(from: image, size: CGSize(width: 8, height: 8)) else { return 0 }
        
        let average = pixels.reduce(0, { $0 + Int($1) }) / pixels.count
        
        var hash: UInt64 = 0
        for (index, pixel) in pixels.enumerated() {
            if Int(pixel) >= average {
                hash |= (1 << (63 - index))
            }
        }
        return hash
    }
    
    private func computeDHash(from image: UIImage) -> UInt64 {
        let width = 9
        let height = 8
        guard let pixels = getGrayscalePixels(from: image, size: CGSize(width: width, height: height)) else { return 0 }
        
        var hash: UInt64 = 0
        var bitIndex = 63
        
        for y in 0..<height {
            for x in 0..<(width - 1) {
                let leftPixelIndex = y * width + x
                let rightPixelIndex = y * width + (x + 1)
                
                if pixels[leftPixelIndex] < pixels[rightPixelIndex] {
                    hash |= (1 << bitIndex)
                }
                bitIndex -= 1
            }
        }
        return hash
    }
    
    private func computeHammingDistance(between hash1: UInt64, and hash2: UInt64) -> UInt64 {
        return UInt64((hash1 ^ hash2).nonzeroBitCount)
    }

    private func getGrayscalePixels(from image: UIImage, size: CGSize) -> [UInt8]? {
        let width = Int(size.width)
        let height = Int(size.height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        
        guard let cgImage = image.cgImage else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let data = context.data else { return nil }
        
        let pixelArray = [UInt8](UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: width * height), count: width * height))
        
        return pixelArray
    }
}