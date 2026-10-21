package com.jrufer.generativeview

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
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
    private var channel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Opened by sharing pictures to the app (not on a restart, which
        // would bring the same share in again).
        if (savedInstanceState == null) receiveShared(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == RemixService.ACTION_OPEN_REMIXES) {
            // A "remix done" notification, tapped while the app was open.
            intent.action = Intent.ACTION_MAIN
            channel?.invokeMethod("openRemixes", null)
            return
        }
        receiveShared(intent)
    }

    // --- Remixes -------------------------------------------------------------

    private var askedForNotifications = false
    private var nextDoneId = 4200

    /**
     * [count] remixes are being waited for: while any are, the waiting
     * service runs (see [RemixService]); at none it stops.
     */
    private fun remixWaiting(count: Int) {
        if (count <= 0) {
            stopService(Intent(this, RemixService::class.java))
            return
        }
        askForNotifications()
        if (RemixService.running) {
            // Already in the foreground: only the count changes.
            RemixService.ensureChannels(this)
            notifications().notify(RemixService.ID_WAITING, RemixService.waiting(this, count))
            return
        }
        val intent = Intent(this, RemixService::class.java).putExtra(RemixService.EXTRA_COUNT, count)
        try {
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
        } catch (e: Exception) {
            // Not allowed from the background: the app waits while it can,
            // and picks up the rest when next opened.
        }
    }

    /** A remix is back: say so, and open the Remixes collection when tapped. */
    private fun remixDone(title: String, text: String) {
        if (!mayNotify()) return
        RemixService.ensureChannels(this)
        val notification = RemixService.builder(this, RemixService.CHANNEL_DONE)
            .setSmallIcon(R.drawable.ic_stat_remix)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(RemixService.openApp(this, true))
            .setAutoCancel(true)
            .build()
        notifications().notify(nextDoneId++, notification)
    }

    private fun notifications() = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun mayNotify(): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    /** Android 13 and later ask once, the first time a remix is sent. */
    private fun askForNotifications() {
        if (askedForNotifications || mayNotify()) return
        askedForNotifications = true
        if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 41)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val media = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "generativeview/media")
        channel = media
        media
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "videoFrame" -> videoFrame(call, result)
                    "copyFile" -> result.success(copyFiles(listOfNotNull(call.argument<String>("path"))))
                    "copyFiles" -> result.success(copyFiles(call.argument<List<String>>("paths") ?: emptyList()))
                    "shareFiles" -> result.success(shareFiles(call.argument<List<String>>("paths") ?: emptyList()))
                    "trashFiles" -> trashFiles(call.argument<List<String>>("paths") ?: emptyList(), result)
                    "takeShared" -> result.success(takeShared())
                    "readCopiedFile" -> readCopiedFile(result)
                    "openUrl" -> result.success(openUrl(call.argument<String>("url")))
                    "trashFile" -> trashFile(call.argument<String>("path"), result)
                    "pasteSource" -> pasteSource(result)
                    "remixWaiting" -> {
                        remixWaiting(call.argument<Int>("count") ?: 0)
                        result.success(null)
                    }
                    "remixDone" -> {
                        remixDone(call.argument<String>("title") ?: "Remix done", call.argument<String>("text") ?: "")
                        result.success(null)
                    }
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

    /** The media files among [paths] that can be handed to another app. */
    private fun shareable(paths: List<String>): List<File> =
        paths.map { File(it) }.filter { it.isFile && CopiedFileProvider.typeOf(it) != null }

    private fun copyFiles(paths: List<String>): Boolean {
        val files = shareable(paths)
        if (files.isEmpty()) return false
        return try {
            val clip = ClipData.newUri(contentResolver, files.first().name, CopiedFileProvider.uriFor(this, files.first()))
            for (file in files.drop(1)) clip.addItem(ClipData.Item(CopiedFileProvider.uriFor(this, file)))
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(clip)
            true
        } catch (e: Exception) {
            false
        }
    }

    // --- Sharing -------------------------------------------------------------

    /**
     * Offer [paths] to another app through the system's share sheet, as the
     * files themselves (so the generation data goes too). The app chosen may
     * read those files, and only those.
     */
    private fun shareFiles(paths: List<String>): Boolean {
        val files = shareable(paths)
        if (files.isEmpty()) return false
        val uris = ArrayList(files.map { CopiedFileProvider.uriFor(this, it) })
        val types = files.mapNotNull { CopiedFileProvider.typeOf(it) }.toSet()
        val type = when {
            types.size == 1 -> types.first()
            types.all { it.startsWith("image/") } -> "image/*"
            types.all { it.startsWith("video/") } -> "video/*"
            else -> "*/*"
        }
        val send = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris.first())
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
        }
        send.type = type
        // The grant travels with the clip data.
        val clip = ClipData.newUri(contentResolver, files.first().name, uris.first())
        for (uri in uris.drop(1)) clip.addItem(ClipData.Item(uri))
        send.clipData = clip
        send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            val title = if (files.size == 1) files.first().name else "${files.size} files"
            startActivity(Intent.createChooser(send, "Share $title").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
            true
        } catch (e: Exception) {
            false
        }
    }

    /** Paths of pictures shared to the app, waiting for the app to take them. */
    private val shared = mutableListOf<String>()

    private fun takeShared(): List<String> {
        val out = shared.toList()
        shared.clear()
        return out
    }

    /** Where pictures shared to the app are kept: a folder of their own. */
    private fun sharedDir(): File {
        val pictures = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "GenerativeView/Shared")
        if ((pictures.isDirectory || pictures.mkdirs()) && pictures.canWrite()) return pictures
        // Without access to shared storage yet: the app's own folder.
        return File(getExternalFilesDir(null) ?: filesDir, "Shared").apply { mkdirs() }
    }

    /**
     * Pictures shared to the app from another (a browser, a chat): copied,
     * byte for byte, into the shared folder, so they can be browsed, searched
     * and remixed like any other. The app is told once they are there.
     */
    private fun receiveShared(intent: Intent?) {
        if (intent == null) return
        val uris = mutableListOf<Uri>()
        @Suppress("DEPRECATION")
        when (intent.action) {
            Intent.ACTION_SEND -> (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris.add(it) }
            Intent.ACTION_SEND_MULTIPLE -> intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
            else -> return
        }
        if (uris.isEmpty()) {
            intent.clipData?.let { clip -> for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris.add(it) } }
        }
        // Handled: a later restart must not bring it in again.
        intent.action = Intent.ACTION_MAIN
        if (uris.isEmpty()) return
        workers.execute {
            val dir = sharedDir()
            val saved = uris.mapNotNull { uri -> saveShared(uri, dir) }
            runOnUiThread {
                if (saved.isEmpty()) return@runOnUiThread
                shared.addAll(saved)
                channel?.invokeMethod("sharedReady", null)
            }
        }
    }

    private fun saveShared(uri: Uri, dir: File): String? = try {
        val type = contentResolver.getType(uri) ?: ""
        var name: String? = null
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) name = c.getString(0)
        }
        val extension = when {
            type == "image/png" -> "png"
            type == "image/jpeg" -> "jpg"
            type == "image/webp" -> "webp"
            type == "image/gif" -> "gif"
            type.startsWith("video/") -> type.removePrefix("video/").let { if (it == "quicktime") "mov" else it }
            else -> "png"
        }
        val base = (name ?: "shared").substringBeforeLast('.').replace(Regex("[\\/:*?\"<>|]"), "_").ifBlank { "shared" }
        val given = (name ?: "").substringAfterLast('.', "").lowercase()
        val ext = if (given.isNotEmpty() && CopiedFileProvider.typeOf(File("x.$given")) != null) given else extension
        var target = File(dir, "$base.$ext")
        var n = 1
        while (target.exists()) {
            target = File(dir, "${base}_${n++}.$ext")
        }
        contentResolver.openInputStream(uri)?.use { input -> target.outputStream().use { input.copyTo(it) } }
        if (target.isFile && target.length() > 0) target.absolutePath else null
    } catch (e: Exception) {
        null
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
    private fun trashFile(path: String?, result: MethodChannel.Result) =
        trashFiles(listOfNotNull(path), result)

    /**
     * Move several files to the trash with one prompt. "unsupported" when any
     * of them can't be trashed this way, so none is touched and the caller
     * deals with them one by one.
     */
    private fun trashFiles(paths: List<String>, result: MethodChannel.Result) {
        if (paths.isEmpty() || Build.VERSION.SDK_INT < Build.VERSION_CODES.R || trashResult != null) {
            result.success("unsupported")
            return
        }
        workers.execute {
            val uris = try {
                paths.map { mediaUriFor(it) }
            } catch (e: Exception) {
                listOf(null)
            }
            runOnUiThread {
                if (uris.any { it == null } || Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                    result.success("unsupported")
                    return@runOnUiThread
                }
                try {
                    val request = MediaStore.createTrashRequest(contentResolver, uris.filterNotNull(), true)
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
