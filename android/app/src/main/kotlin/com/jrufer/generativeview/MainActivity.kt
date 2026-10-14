package com.jrufer.generativeview

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.OpenableColumns
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
                    "trashFile" -> trashFile(call.argument<String>("path"), result)
                    "pasteSource" -> pasteSource(result)
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

    // --- Deleting and pasting ----------------------------------------------

    private var trashResult: MethodChannel.Result? = null

    /**
     * Move a file to the system trash (Android 11+), through MediaStore, which
     * asks the user itself. Answers "trashed", "cancelled", or "unsupported"
     * when the file can't be trashed (older Android, or a file MediaStore
     * doesn't know), so the caller can offer to delete it outright.
     */
    private fun trashFile(path: String?, result: MethodChannel.Result) {
        if (path == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.R || trashResult != null) {
            result.success("unsupported")
            return
        }
        workers.execute {
            val uri = try {
                mediaUriFor(path)
            } catch (e: Exception) {
                null
            }
            runOnUiThread {
                if (uri == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                    result.success("unsupported")
                    return@runOnUiThread
                }
                try {
                    val request = MediaStore.createTrashRequest(contentResolver, listOf(uri), true)
                    trashResult = result
                    startIntentSenderForResult(request.intentSender, TRASH_REQUEST, null, 0, 0, 0)
                } catch (e: Exception) {
                    trashResult = null
                    result.success("unsupported")
                }
            }
        }
    }

    /** The MediaStore address of the file at [path], if it has one. */
    private fun mediaUriFor(path: String): Uri? {
        val files = MediaStore.Files.getContentUri("external")
        contentResolver.query(
            files,
            arrayOf(MediaStore.Files.FileColumns._ID),
            "${MediaStore.Files.FileColumns.DATA} = ?",
            arrayOf(path),
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) return ContentUris.withAppendedId(files, cursor.getLong(0))
        }
        return null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == TRASH_REQUEST) {
            val result = trashResult
            trashResult = null
            result?.success(if (resultCode == Activity.RESULT_OK) "trashed" else "cancelled")
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    /**
     * What a paste would bring in: {"path"} for a file of ours copied with
     * Copy image, otherwise {"bytes", "type", "name"} read through the
     * clipboard's address; null when it holds no picture or video.
     */
    private fun pasteSource(result: MethodChannel.Result) {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val uri = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
        if (uri == null) {
            result.success(null)
            return
        }
        if (uri.authority == packageName + ".copied") {
            val path = uri.path
            if (path != null && File(path).isFile) {
                result.success(mapOf("path" to path))
                return
            }
        }
        workers.execute {
            val found: Map<String, Any>? = try {
                val type = contentResolver.getType(uri)
                if (type == null || !(type.startsWith("image/") || type.startsWith("video/"))) {
                    null
                } else {
                    var name: String? = null
                    contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                        if (c.moveToFirst()) name = c.getString(0)
                    }
                    val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                    if (bytes == null) null else buildMap {
                        put("bytes", bytes)
                        put("type", type)
                        name?.let { put("name", it) }
                    }
                }
            } catch (e: Exception) {
                null
            }
            runOnUiThread { result.success(found) }
        }
    }

    companion object {
        private const val TRASH_REQUEST = 4101
    }

    override fun onDestroy() {
        workers.shutdown()
        super.onDestroy()
    }
}
