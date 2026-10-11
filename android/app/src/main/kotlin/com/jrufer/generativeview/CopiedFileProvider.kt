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

/**
 * Hands a copied image or video to whichever app it is pasted into, byte for
 * byte, so the generation data stored in the file goes with it.
 *
 * "Copy image" puts a content:// address for the file on the clipboard; the
 * system lets the app that pastes it read that one address, and nothing else.
 * The provider is not exported and only ever serves media files.
 */
class CopiedFileProvider : ContentProvider() {
    companion object {
        private val TYPES = mapOf(
            "png" to "image/png",
            "jpg" to "image/jpeg",
            "jpeg" to "image/jpeg",
            "webp" to "image/webp",
            "gif" to "image/gif",
            "bmp" to "image/bmp",
            "mp4" to "video/mp4",
            "m4v" to "video/mp4",
            "mov" to "video/quicktime",
            "webm" to "video/webm",
            "mkv" to "video/x-matroska",
        )

        fun typeOf(file: File): String? = TYPES[file.extension.lowercase()]

        /** The address under which [file] can be read by another app. */
        fun uriFor(context: Context, file: File): Uri =
            Uri.Builder()
                .scheme(ContentResolver.SCHEME_CONTENT)
                .authority(context.packageName + ".copied")
                .path(file.absolutePath)
                .build()
    }

    private fun fileFor(uri: Uri): File? {
        val path = uri.path ?: return null
        val file = File(path)
        return if (file.isFile && typeOf(file) != null) file else null
    }

    override fun onCreate(): Boolean = true

    override fun getType(uri: Uri): String? = fileFor(uri)?.let { typeOf(it) }

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
