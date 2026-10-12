package com.jrufer.generativeview

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    // The Rust core decodes images itself but has no video decoder on
    // Android, so it asks for a frame here when it needs a video thumbnail.
    private val workers = Executors.newFixedThreadPool(2)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "generativeview/media")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "videoFrame" -> videoFrame(call, result)
                    "copyFile" -> result.success(copyFile(call.argument<String>("path")))
                    "readCopiedFile" -> readCopiedFile(result)
                    "openUrl" -> result.success(openUrl(call.argument<String>("url")))
                    else -> result.notImplemented()
                }
            }
    }

    private fun videoFrame(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path == null) {
            result.error("args", "path is required", null)
            return
        }
        workers.execute {
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

    // "Copy image": the clipboard gets an address for the file itself (see
    // CopiedFileProvider), not a re-encoded picture, so whatever it is pasted
    // into receives the original bytes, generation data included.
    /** Open a web page in the user's browser. */
    private fun openUrl(url: String?): Boolean {
        if (url == null || !(url.startsWith("https://") || url.startsWith("http://"))) return false
        return try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun copyFile(path: String?): Boolean {
        val file = path?.let { File(it) } ?: return false
        if (!file.isFile || CopiedFileProvider.typeOf(file) == null) return false
        return try {
            val clip = ClipData.newUri(contentResolver, file.name, CopiedFileProvider.uriFor(this, file))
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(clip)
            true
        } catch (e: Exception) {
            false
        }
    }

    // What an app pasting the clipboard would read. Used by the integration
    // test to check that a copied image arrives unchanged.
    private fun readCopiedFile(result: MethodChannel.Result) {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val uri = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
        if (uri == null) {
            result.success(null)
            return
        }
        workers.execute {
            val bytes = try {
                contentResolver.openInputStream(uri)?.use { it.readBytes() }
            } catch (e: Exception) {
                null
            }
            runOnUiThread { result.success(bytes) }
        }
    }

    override fun onDestroy() {
        workers.shutdown()
        super.onDestroy()
    }
}
