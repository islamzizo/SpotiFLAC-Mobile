package com.zarz.spotiflac

import java.io.File
import java.io.IOException

/** One workspace per process; in-flight media must survive cache eviction. */
internal class NativeMediaWorkspace(privateDirectory: File) {
    val directory = File(privateDirectory, "native-media-work")

    init {
        // These app-owned scratch files cannot resume after process death.
        // Reclaim them once at startup, before any download or scan can begin.
        ensureDirectory().listFiles()?.forEach { it.delete() }
    }

    fun ensureDirectory(): File {
        if (!directory.mkdirs() && !directory.isDirectory) {
            throw IOException("Could not prepare native media workspace: ${directory.path}")
        }
        return directory
    }

    fun createTemporaryFile(prefix: String, suffix: String): File =
        File.createTempFile(prefix, suffix, ensureDirectory())
}
