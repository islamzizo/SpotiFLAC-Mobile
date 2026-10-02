package com.zarz.spotiflac

import java.io.File

/** Failure belongs to this read, never to a different document or provider.
 * The direct callback owns and closes its descriptor before fallback starts. */
internal fun <T> readSafMetadataWithFallback(
    directRead: () -> T?,
    fallbackRead: () -> T?,
    accept: (T) -> Boolean = { true },
    retryDirectOnFailure: Boolean = false,
): T? {
    fun attempt(read: () -> T?): T? = try {
        read()?.takeIf(accept)
    } catch (_: Exception) { null }

    val direct = attempt(directRead)
    if (direct != null) return direct
    val copied = attempt(fallbackRead)
    if (copied != null) return copied
    // A remote provider may have completed its download/cache by now. Reopen
    // once; never repeatedly copy whole songs or publish filename guesses.
    return if (retryDirectOnFailure) attempt(directRead) else null
}

internal fun <T> readLyricsWithSafCopy(
    path: String,
    copyToTemp: (String) -> File?,
    read: (String) -> T,
): T? {
    if (!path.startsWith("content://")) return read(path)
    val temporary = copyToTemp(path) ?: return null
    return try {
        read(temporary.absolutePath)
    } finally {
        temporary.delete()
    }
}
