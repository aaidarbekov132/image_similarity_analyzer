package com.example.image_similarity_analyzer

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Size
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry.RequestPermissionsResultListener
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

data class ImageFingerprint(val assetId: String, val dHash: Long, val aHash: Long)

class ImageSimilarityAnalyzerPlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var progressChannel: EventChannel
    private var pluginBinding: FlutterPlugin.FlutterPluginBinding? = null
    private var activityBinding: ActivityPluginBinding? = null

    private var pendingResult: Result? = null
    private var pendingThreshold: Int = DEFAULT_DHASH_THRESHOLD

    private val PERMISSION_REQUEST_CODE = 47291

    private val mainHandler = Handler(Looper.getMainLooper())

    private val executor = Executors.newFixedThreadPool(
        Runtime.getRuntime().availableProcessors().coerceAtLeast(4)
    )

    private val fingerprints: MutableList<ImageFingerprint> =
        Collections.synchronizedList(mutableListOf())

    @Volatile
    private var isScanning = false

    @Volatile
    private var progressSink: EventChannel.EventSink? = null

    companion object {
        private const val DEFAULT_DHASH_THRESHOLD = 5
        private const val PROGRESS_REPORT_EVERY = 25
    }

    // ── FlutterPlugin ────────────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        pluginBinding = binding
        channel = MethodChannel(binding.binaryMessenger, "image_similarity_analyzer")
        channel.setMethodCallHandler(this)

        progressChannel = EventChannel(
            binding.binaryMessenger,
            "image_similarity_analyzer/progress"
        )
        progressChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                progressSink = events
            }

            override fun onCancel(arguments: Any?) {
                progressSink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        progressChannel.setStreamHandler(null)
        progressSink = null
        pluginBinding = null
        executor.shutdown()
    }

    // ── ActivityAware ────────────────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
    }

    // ── MethodCallHandler ────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "scanLibraryForSimilar" -> {
                val threshold = call.argument<Int>("dHashDistanceThreshold")
                    ?: DEFAULT_DHASH_THRESHOLD
                requestPermissionAndScan(threshold, result)
            }
            else -> result.notImplemented()
        }
    }

    // ── Permission handling ───────────────────────────────────────────────────

    private fun requiredPermission(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
            Manifest.permission.READ_MEDIA_IMAGES
        else
            Manifest.permission.READ_EXTERNAL_STORAGE

    private fun hasPermission(): Boolean {
        val ctx = pluginBinding?.applicationContext ?: return false
        return ContextCompat.checkSelfPermission(ctx, requiredPermission()) ==
                PackageManager.PERMISSION_GRANTED
    }

    private fun requestPermissionAndScan(threshold: Int, result: Result) {
        if (hasPermission()) {
            scanInBackground(threshold, result)
            return
        }
        val activity = activityBinding?.activity
        if (activity == null) {
            result.success(emptyList<List<String>>())
            return
        }
        pendingResult = result
        pendingThreshold = threshold
        activity.requestPermissions(arrayOf(requiredPermission()), PERMISSION_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val result = pendingResult ?: return true
        pendingResult = null
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            scanInBackground(pendingThreshold, result)
        } else {
            result.success(emptyList<List<String>>())
        }
        return true
    }

    // ── Scanning ─────────────────────────────────────────────────────────────

    private fun scanInBackground(threshold: Int, result: Result) {
        executor.submit {
            try {
                val groups = scanLibraryForSimilar(threshold)
                mainHandler.post { result.success(groups) }
            } catch (e: Exception) {
                mainHandler.post { result.error("SCAN_ERROR", e.message, null) }
            }
        }
    }

    private fun scanLibraryForSimilar(dHashThreshold: Int): List<List<String>> {
        if (isScanning) return emptyList()
        isScanning = true

        return try {
            val ctx = pluginBinding?.applicationContext ?: return emptyList()
            fingerprints.clear()

            val projection = arrayOf(MediaStore.Images.Media._ID)
            val sortOrder = "${MediaStore.Images.Media.DATE_ADDED} DESC"

            val imageIds = mutableListOf<Long>()
            ctx.contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                projection,
                null,
                null,
                sortOrder
            )?.use { cursor ->
                val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                while (cursor.moveToNext()) {
                    imageIds.add(cursor.getLong(idColumn))
                }
            }

            val total = imageIds.size
            if (total == 0) {
                emitProgress(0, 0, "done")
                return emptyList()
            }

            emitProgress(0, total, "scanning")
            val processed = AtomicInteger(0)

            val batchSize = 50
            var batchStart = 0
            while (batchStart < total) {
                val batchEnd = minOf(batchStart + batchSize, total)
                val batch = imageIds.subList(batchStart, batchEnd)
                val latch = CountDownLatch(batch.size)

                for (id in batch) {
                    executor.submit {
                        try {
                            computeImageFingerprints(ctx, id)
                        } finally {
                            val n = processed.incrementAndGet()
                            if (n % PROGRESS_REPORT_EVERY == 0 || n == total) {
                                emitProgress(n, total, "scanning")
                            }
                            latch.countDown()
                        }
                    }
                }

                latch.await()
                batchStart += batchSize
            }

            emitProgress(total, total, "clustering")
            val groups = clusterSimilarImages(dHashThreshold)
            emitProgress(total, total, "done")
            groups
        } finally {
            isScanning = false
        }
    }

    private fun emitProgress(processed: Int, total: Int, phase: String) {
        val sink = progressSink ?: return
        val event = mapOf(
            "processed" to processed,
            "total" to total,
            "phase" to phase
        )
        mainHandler.post { sink.success(event) }
    }

    // ── Fingerprint computation ───────────────────────────────────────────────

    private fun computeImageFingerprints(ctx: Context, id: Long) {
        val uri = ContentUris.withAppendedId(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id
        )
        val thumbnail = loadThumbnail(ctx, uri) ?: return
        try {
            val scaled = Bitmap.createScaledBitmap(thumbnail, 9, 8, true)
            val pixels = IntArray(72)
            scaled.getPixels(pixels, 0, 9, 0, 0, 9, 8)
            if (scaled !== thumbnail) scaled.recycle()

            val dHash = computeDHash(pixels)
            val aHash = computeAHash(pixels)
            val fingerprint = ImageFingerprint(
                assetId = id.toString(),
                dHash = dHash,
                aHash = aHash
            )
            fingerprints.add(fingerprint)
        } finally {
            thumbnail.recycle()
        }
    }

    private fun loadThumbnail(ctx: Context, uri: Uri): Bitmap? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ctx.contentResolver.loadThumbnail(uri, Size(64, 64), null)
            } else {
                val id = ContentUris.parseId(uri)
                @Suppress("DEPRECATION")
                MediaStore.Images.Thumbnails.getThumbnail(
                    ctx.contentResolver,
                    id,
                    MediaStore.Images.Thumbnails.MICRO_KIND,
                    null
                )
            }
        } catch (e: Exception) {
            null
        }
    }

    // ── Hash algorithms ───────────────────────────────────────────────────────

    // dHash: 9×8 grid, bit = 1 if left pixel < right pixel.
    internal fun computeDHash(pixels: IntArray): Long {
        var hash = 0L
        var bitIndex = 63
        for (y in 0 until 8) {
            for (x in 0 until 8) {
                val leftLuma = luminance(pixels[y * 9 + x])
                val rightLuma = luminance(pixels[y * 9 + (x + 1)])
                if (leftLuma < rightLuma) {
                    hash = hash or (1L shl bitIndex)
                }
                bitIndex--
            }
        }
        return hash
    }

    // aHash: 8×8 grid, bit = 1 if pixel luminance >= average.
    // Reuses the 9×8 buffer by reading the first 8 columns of each row.
    internal fun computeAHash(pixels: IntArray): Long {
        val lumas = IntArray(64)
        for (y in 0 until 8) {
            for (x in 0 until 8) {
                lumas[y * 8 + x] = luminance(pixels[y * 9 + x])
            }
        }
        val average = lumas.sum() / 64

        var hash = 0L
        for (i in 0 until 64) {
            if (lumas[i] >= average) {
                hash = hash or (1L shl (63 - i))
            }
        }
        return hash
    }

    // BT.601 integer approximation: (77R + 150G + 29B) >> 8 ≈ 0.299R + 0.587G + 0.114B
    private fun luminance(pixel: Int): Int {
        val r = Color.red(pixel)
        val g = Color.green(pixel)
        val b = Color.blue(pixel)
        return (77 * r + 150 * g + 29 * b) shr 8
    }

    internal fun hammingDistance(h1: Long, h2: Long): Int =
        java.lang.Long.bitCount(h1 xor h2)

    // ── Clustering ────────────────────────────────────────────────────────────

    // O(N²) pairwise comparison on dHash with Hamming distance threshold.
    // Transitive grouping via Union-Find: if A~B and B~C then {A,B,C} is one group.
    private fun clusterSimilarImages(dHashThreshold: Int): List<List<String>> {
        val snapshot: List<ImageFingerprint> = synchronized(fingerprints) {
            fingerprints.toList()
        }
        val n = snapshot.size
        if (n < 2) return emptyList()

        val dsu = UnionFind(n)
        for (i in 0 until n) {
            val a = snapshot[i]
            for (j in (i + 1) until n) {
                val b = snapshot[j]
                if (hammingDistance(a.dHash, b.dHash) <= dHashThreshold) {
                    dsu.union(i, j)
                }
            }
        }

        val byRoot = HashMap<Int, MutableList<String>>()
        for (i in 0 until n) {
            val root = dsu.find(i)
            byRoot.getOrPut(root) { mutableListOf() }.add(snapshot[i].assetId)
        }
        return byRoot.values.filter { it.size > 1 }
    }

    private class UnionFind(size: Int) {
        private val parent = IntArray(size) { it }
        private val rank = IntArray(size)

        fun find(x: Int): Int {
            var root = x
            while (parent[root] != root) root = parent[root]
            var cur = x
            while (parent[cur] != root) {
                val next = parent[cur]
                parent[cur] = root
                cur = next
            }
            return root
        }

        fun union(a: Int, b: Int) {
            val ra = find(a)
            val rb = find(b)
            if (ra == rb) return
            when {
                rank[ra] < rank[rb] -> parent[ra] = rb
                rank[ra] > rank[rb] -> parent[rb] = ra
                else -> { parent[rb] = ra; rank[ra]++ }
            }
        }
    }
}
