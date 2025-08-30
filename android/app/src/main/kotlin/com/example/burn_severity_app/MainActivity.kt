package com.example.burn_severity_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.os.*
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.pytorch.IValue
import org.pytorch.LiteModuleLoader
import org.pytorch.Module
import org.pytorch.Tensor
import org.pytorch.torchvision.TensorImageUtils
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.Executors
import kotlin.math.ln
import kotlin.math.min

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "BurnInfer"
        private const val CHANNEL = "burn_infer"

        private const val MODEL_ASSET_ANDROID = "models/burn_cpu_v1.ptl"
        private const val LABELS_ASSET_ANDROID = "models/labels.txt"
        private const val INPUT_SIZE = 224

        // ---------- Open-set rejection thresholds (stricter) ----------
        private const val ACCEPT_HARD = 0.82f
        private const val MIN_CONFIDENCE = 0.55f
        private const val MIN_MARGIN = 0.10f
        private const val UNIFORM_GAP = 0.34f     // top - (1/nClasses) must be >= this (~0.67 for 3 classes)

        private const val MAX_ENTROPY = 0.58f     // lower = stricter uncertainty
        private const val MIN_SKIN_FRACTION = 0.14f
        private const val DEBUG_BYPASS_SKIN_CHECK = false

        // Hard redness-on-skin gates
        private const val MIN_RED_ON_SKIN = 0.12f
        private const val MIN_LARGEST_BLOB_FRAC = 0.04f   // largest contiguous red-on-skin region

        // Tiny TTA consistency (orig vs. flip)
        private const val MAX_JSD = 0.06f         // Jensen–Shannon divergence threshold

        private val CANONICAL = listOf(
            "First-degree burn", "Second-degree burn", "Third-degree burn"
        )
        private val NON_BURN_SYNONYMS = setOf(
            "other","non-burn","nonburn","background","bg","not burn","not_burn","no burn","negative","none"
        )

        // ---------- Utils ----------
        private fun copyAssetToFile(context: Context, assetPath: String): String {
            val outFile = File(context.filesDir, assetPath)
            if (!outFile.exists()) {
                outFile.parentFile?.mkdirs()
                context.assets.open(assetPath).use { input ->
                    FileOutputStream(outFile).use { output -> input.copyTo(output) }
                }
            }
            return outFile.absolutePath
        }

        private fun readAssetText(context: Context, assetPath: String): String {
            context.assets.open(assetPath).use { ins -> return ins.bufferedReader().readText() }
        }

        private fun md5(bytes: ByteArray): String {
            val md = MessageDigest.getInstance("MD5")
            md.update(bytes)
            return md.digest().joinToString("") { "%02x".format(it) }
        }

        private fun centerCropAndResize(src: Bitmap, size: Int): Bitmap {
            val w = src.width
            val h = src.height
            val side = min(w, h)
            val x = (w - side) / 2
            val y = (h - side) / 2
            val square = Bitmap.createBitmap(src, x, y, side, side)
            return Bitmap.createScaledBitmap(square, size, size, true)
        }

        // ---- Redness on detected skin with largest-blob statistic ----
        // Returns Triple: (redOnSkinFrac, globalSkinFrac, largestBlobFrac)
        private fun redOnSkinStats(src: Bitmap): Triple<Float, Float, Float> {
            val target = 128
            val w = target
            val h = target
            val scaled = Bitmap.createScaledBitmap(src, w, h, true)
            val total = w * h
            val px = IntArray(total)
            scaled.getPixels(px, 0, w, 0, 0, w, h)

            // Build mask: true if (skin && red)
            val mask = BooleanArray(total)
            var skinCount = 0
            var redOnSkinCount = 0
            for (i in 0 until total) {
                val c = px[i]
                val r = (c shr 16) and 0xff
                val g = (c shr 8) and 0xff
                val b = c and 0xff

                val y  = (0.299*r + 0.587*g + 0.114*b).toInt()
                val cb = ((b - y) * 0.564 + 128).toInt()
                val cr = ((r - y) * 0.713 + 128).toInt()
                val isSkin = (cr in 133..173 && cb in 77..127)
                if (isSkin) {
                    skinCount++
                    val isRed = (r > g + 18 && r > b + 18 && r > 90)
                    if (isRed) {
                        mask[i] = true
                        redOnSkinCount++
                    }
                }
            }
            val skinFrac = if (total > 0) skinCount.toFloat() / total else 0f
            val redOnSkinFrac = if (skinCount > 0) redOnSkinCount.toFloat() / skinCount else 0f

            // Largest connected component (4-neighbor) on mask
            var largest = 0
            val visited = BooleanArray(total)
            val qx = IntArray(total)
            val qy = IntArray(total)
            fun idx(x: Int, y: Int) = y * w + x

            for (y in 0 until h) {
                for (x in 0 until w) {
                    val i0 = idx(x, y)
                    if (!mask[i0] || visited[i0]) continue
                    // BFS
                    var head = 0
                    var tail = 0
                    qx[tail] = x; qy[tail] = y; tail++
                    visited[i0] = true
                    var size = 0
                    while (head < tail) {
                        val cx = qx[head]
                        val cy = qy[head]
                        head++
                        size++
                        // 4-neighbors
                        val neigh = arrayOf(
                            cx - 1 to cy,
                            cx + 1 to cy,
                            cx to cy - 1,
                            cx to cy + 1
                        )
                        for ((nx, ny) in neigh) {
                            if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue
                            val j = idx(nx, ny)
                            if (!visited[j] && mask[j]) {
                                visited[j] = true
                                qx[tail] = nx; qy[tail] = ny; tail++
                            }
                        }
                    }
                    if (size > largest) largest = size
                }
            }
            val largestBlobFrac = if (total > 0) largest.toFloat() / total else 0f
            return Triple(redOnSkinFrac, skinFrac, largestBlobFrac)
        }

        private fun softmax(logits: FloatArray): FloatArray {
            var maxv = logits[0]
            for (i in 1 until logits.size) if (logits[i] > maxv) maxv = logits[i]
            var sum = 0.0
            val probs = FloatArray(logits.size)
            for (i in logits.indices) {
                val e = kotlin.math.exp((logits[i] - maxv).toDouble())
                probs[i] = e.toFloat()
                sum += e
            }
            val inv = (1.0 / sum).toFloat()
            for (i in probs.indices) probs[i] *= inv
            return probs
        }

        private fun entropy(probs: FloatArray): Float {
            var h = 0.0
            for (p in probs) if (p > 1e-8) h -= p * ln(p.toDouble())
            return h.toFloat()
        }

        // Jensen–Shannon divergence between two distributions (base-e)
        private fun jsd(p: FloatArray, q: FloatArray): Float {
            fun kl(a: FloatArray, b: FloatArray): Double {
                var s = 0.0
                for (i in a.indices) if (a[i] > 1e-8 && b[i] > 1e-8)
                    s += a[i] * kotlin.math.ln((a[i] / b[i]).toDouble())
                return s
            }
            val m = FloatArray(p.size) { i -> 0.5f * (p[i] + q[i]) }
            val d = 0.5 * kl(p, m) + 0.5 * kl(q, m)
            return d.toFloat()
        }

        private data class Top2(val topIdx: Int, val top: Float, val second: Float)

        private fun top2(probs: FloatArray): Top2 {
            var topIdx = 0
            var top = probs[0]
            var second = 0f
            for (i in 1 until probs.size) {
                val p = probs[i]
                if (p > top) { second = top; top = p; topIdx = i }
                else if (p > second) { second = p }
            }
            return Top2(topIdx, top, second)
        }

        private fun mapToCanonicalText(label: String?): String? {
            if (label == null) return null
            val l = label.trim()
            if (CANONICAL.any { it.equals(l, ignoreCase = true) }) {
                return CANONICAL.first { it.equals(l, true) }
            }
            val low = l.lowercase()
            if (low in NON_BURN_SYNONYMS) return null
            return when {
                "1st" in low || "first" in low  -> "First-degree burn"
                "2nd" in low || "second" in low -> "Second-degree burn"
                "3rd" in low || "third" in low  -> "Third-degree burn"
                else -> null
            }
        }
    }

    private var module: Module? = null
    private var labels: List<String> = emptyList()
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    // Instance helper so we can pass the module explicitly
    private fun probsForwardWith(mdl: Module, bmp: Bitmap, mean: FloatArray, std: FloatArray): FloatArray {
        val t = TensorImageUtils.bitmapToFloat32Tensor(bmp, mean, std)
        val logits = mdl.forward(IValue.from(t)).toTensor().dataAsFloatArray
        return softmax(logits)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "infer" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("ARG", "missing 'path'", null)
                        } else {
                            io.execute {
                                try {
                                    ensureLoaded()

                                    val mdl = module ?: throw IllegalStateException("Model not loaded")
                                    val original = BitmapFactory.decodeFile(path)
                                        ?: throw RuntimeException("Bitmap decode failed for $path")

                                    // Hard gate features: red-on-skin stats + largest blob
                                    val (redOnSkin, skinFracROS, blobFrac) = redOnSkinStats(original)
                                    val skinFrac = if (DEBUG_BYPASS_SKIN_CHECK) 1f else skinFracROS

                                    // Center-crop + resize for model input
                                    val bmp = centerCropAndResize(original, INPUT_SIZE)

                                    // Horizontal flip for TTA
                                    val matrix = Matrix().apply { preScale(-1f, 1f) }
                                    val bmpFlip = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, matrix, true)

                                    // 3 normalizations, both orig & flip
                                    fun runAllWith(b: Bitmap): List<FloatArray> = listOf(
                                        probsForwardWith(mdl, b, TensorImageUtils.TORCHVISION_NORM_MEAN_RGB, TensorImageUtils.TORCHVISION_NORM_STD_RGB),
                                        probsForwardWith(mdl, b, floatArrayOf(0f,0f,0f), floatArrayOf(1f,1f,1f)),
                                        probsForwardWith(mdl, b, floatArrayOf(0.5f,0.5f,0.5f), floatArrayOf(0.5f,0.5f,0.5f))
                                    )
                                    val probsOrig = runAllWith(bmp)
                                    val probsFlip = runAllWith(bmpFlip)

                                    // Candidate = average(orig, flip); pick the one with highest top prob
                                    fun avg(a: FloatArray, b: FloatArray): FloatArray {
                                        val out = FloatArray(a.size) { i -> 0.5f*(a[i]+b[i]) }
                                        return out
                                    }
                                    val candidates = listOf(
                                        avg(probsOrig[0], probsFlip[0]),
                                        avg(probsOrig[1], probsFlip[1]),
                                        avg(probsOrig[2], probsFlip[2])
                                    )
                                    val picked = candidates.maxByOrNull { arr -> arr.maxOrNull() ?: 0f } ?: candidates[0]
                                    val pickedIdx = candidates.indexOf(picked)

                                    val t = top2(picked)
                                    val H = entropy(picked)
                                    val nClasses = if (labels.isEmpty()) 3f else labels.size.toFloat()
                                    val uniform = 1f / nClasses
                                    val topOverUniform = t.top - uniform

                                    // JSD between orig and flip for the chosen norm
                                    val jsdVal = jsd(probsOrig[pickedIdx], probsFlip[pickedIdx])

                                    // Mapping to canonical label
                                    val mappedByIndex: String? = if (labels.size == 3) {
                                        when (t.topIdx) {
                                            0 -> "First-degree burn"
                                            1 -> "Second-degree burn"
                                            2 -> "Third-degree burn"
                                            else -> null
                                        }
                                    } else null
                                    val raw = if (labels.isNotEmpty() && t.topIdx < labels.size) labels[t.topIdx].trim() else null
                                    val mappedByText = mapToCanonicalText(raw)
                                    val nonBurn = raw?.lowercase()?.let { it in NON_BURN_SYNONYMS } == true
                                    val mapped = when {
                                        nonBurn -> null
                                        mappedByIndex != null -> mappedByIndex
                                        else -> mappedByText
                                    }

                                    // ---------------- DECISION ----------------
                                    val passSkin = skinFrac >= MIN_SKIN_FRACTION
                                    val passRedOnSkin = redOnSkin >= MIN_RED_ON_SKIN
                                    val passBlob = blobFrac >= MIN_LARGEST_BLOB_FRAC
                                    val entropyOk = H <= MAX_ENTROPY
                                    val acceptDirect = t.top >= ACCEPT_HARD
                                    val acceptByRule = (t.top >= MIN_CONFIDENCE && (t.top - t.second) >= MIN_MARGIN && topOverUniform >= UNIFORM_GAP)
                                    val ttaConsistent = jsdVal <= MAX_JSD

                                    val finalLabel: String = if (mapped == null) {
                                        "Burn not detected"
                                    } else if (!(passSkin && passRedOnSkin && passBlob)) {
                                        "Burn not detected"
                                    } else if (!entropyOk) {
                                        "Burn not detected"
                                    } else if (!(acceptDirect || acceptByRule)) {
                                        "Burn not detected"
                                    } else if (!ttaConsistent) {
                                        "Burn not detected"
                                    } else {
                                        mapped
                                    }

                                    // Logging
                                    val probsStr = picked.map { p -> "%.2f".format(p) }.joinToString(", ")
                                    Log.i(
                                        TAG,
                                        "skin=${"%.3f".format(skinFrac)} redOnSkin=${"%.3f".format(redOnSkin)} blobFrac=${"%.3f".format(blobFrac)} " +
                                                "H=${"%.3f".format(H)} top=${"%.3f".format(t.top)} " +
                                                "margin=${"%.3f".format(t.top - t.second)} " +
                                                "topOverUniform=${"%.3f".format(topOverUniform)} JSD=${"%.3f".format(jsdVal)} " +
                                                "raw=$raw -> $finalLabel | pickedProbs=[$probsStr]"
                                    )

                                    main.post { result.success(finalLabel) }
                                } catch (e: Exception) {
                                    Log.e(TAG, "INFER failed", e)
                                    main.post { result.error("INFER", "load_or_infer_failed: ${e.message}", null) }
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun ensureLoaded() {
        if (module != null) return
        val modelPath = copyAssetToFile(this, MODEL_ASSET_ANDROID)
        Log.i(TAG, "Loading model from: $modelPath")
        assets.open(MODEL_ASSET_ANDROID).use { ins ->
            val bytes = ins.readBytes()
            Log.i(TAG, "Model bytes=${bytes.size}, md5=${md5(bytes)}")
        }
        module = LiteModuleLoader.load(modelPath)
        labels = readAssetText(this, LABELS_ASSET_ANDROID)
            .lines().map { it.trim() }.filter { it.isNotEmpty() }
        Log.i(TAG, "Labels loaded (${labels.size}): $labels")
    }
}
