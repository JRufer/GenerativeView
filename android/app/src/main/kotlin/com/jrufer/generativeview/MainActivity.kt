package com.jrufer.generativeview

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    // The Rust core decodes images itself but has no video decoder on
    // Android, so it asks for a frame here when it needs a video thumbnail.
    private val frameWorkers = Executors.newFixedThreadPool(2)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "generativeview/media")
            .setMethodCallHandler { call, result ->
                if (call.method != "videoFrame") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("args", "path is required", null)
                    return@setMethodCallHandler
                }
                frameWorkers.execute {
                    val jpeg = try {
                        firstFrameJpeg(path)
                    } catch (e: Exception) {
                        null
                    }
                    runOnUiThread {
                        if (jpeg != null) {
                            result.success(jpeg)
                        } else {
                            result.error("decode", "could not read a frame from $path", null)
                        }
                    }
                }
            }
    }

    private fun firstFrameJpeg(path: String): ByteArray? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val frame: Bitmap = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: return null
            val out = ByteArrayOutputStream()
            frame.compress(Bitmap.CompressFormat.JPEG, 90, out)
            frame.recycle()
            return out.toByteArray()
        } finally {
            retriever.release()
        }
    }

    override fun onDestroy() {
        frameWorkers.shutdown()
        super.onDestroy()
    }
}
