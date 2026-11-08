package com.jrufer.generativeview

import android.content.ContentProvider
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException
import java.security.MessageDigest

/**
 * Hands a downloaded update to the system installer.
 *
 * The app downloads a newer build's APK into `cache/updates` and opens it
 * with a content:// address from here; the installer is granted that one
 * address. Not exported, read-only, and it serves nothing but APKs in that
 * folder.
 */
class UpdateFileProvider : ContentProvider() {
    companion object {
        const val APK_TYPE = "application/vnd.android.package-archive"

        private fun folder(context: Context): File = File(context.cacheDir, "updates")

        /** [path] as a file this provider will serve, or null if it is not one. */
        fun fileFor(context: Context, path: String): File? {
            val file = File(path).canonicalFile
            val inside = file.parentFile?.canonicalPath == folder(context).canonicalPath
            return if (inside && file.isFile && file.name.endsWith(".apk")) file else null
        }

        /** The address under which the installer can read [file]. */
        fun uriFor(context: Context, file: File): Uri =
            Uri.Builder()
                .scheme(ContentResolver.SCHEME_CONTENT)
                .authority(context.packageName + ".updates")
                .appendPath(file.name)
                .build()

        /** [file]'s SHA-256, as lowercase hex. */
        fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(1 shl 16)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    digest.update(buffer, 0, n)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
    }

    private fun fileFor(uri: Uri): File? {
        val context = context ?: return null
        val name = uri.lastPathSegment ?: return null
        if (name.contains('/') || name == "." || name == "..") return null
        return fileFor(context, File(folder(context), name).path)
    }

    override fun onCreate(): Boolean = true

    override fun getType(uri: Uri): String? = fileFor(uri)?.let { APK_TYPE }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        val file = fileFor(uri) ?: throw FileNotFoundException(uri.toString())
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? {
        val file = fileFor(uri) ?: return null
        val columns: Array<String> =
            projection?.map { it }?.toTypedArray()
                ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val cursor = MatrixCursor(columns, 1)
        val row = cursor.newRow()
        for (column in columns) {
            when (column) {
                OpenableColumns.DISPLAY_NAME -> row.add(file.name)
                OpenableColumns.SIZE -> row.add(file.length())
                else -> row.add(null)
            }
        }
        return cursor
    }

    // Read-only.
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0
}
