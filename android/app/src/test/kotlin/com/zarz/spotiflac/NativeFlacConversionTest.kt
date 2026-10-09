package com.zarz.spotiflac

import java.io.File
import java.nio.file.Files
import java.util.concurrent.CancellationException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class NativeFlacConversionTest {
    private fun withFiles(block: (File, File) -> Unit) {
        val directory = Files.createTempDirectory("native-flac-conversion-").toFile()
        try {
            val input = File(directory, "input.m4a").apply { writeText("original audio") }
            block(input, File(directory, "output.partial.flac"))
            assertEquals("original audio", input.readText())
        } finally {
            directory.deleteRecursively()
        }
    }

    private fun writeFlacHeader(file: File) {
        file.writeBytes(byteArrayOf(0x66, 0x4c, 0x61, 0x43) + ByteArray(64))
    }

    @Test
    fun validRemuxSkipsEncoderAndLeavesSourceUntouched() = withFiles { input, output ->
        val commands = mutableListOf<List<String>>()
        convertToStagedFlac(input.path, output.path, "flac", { arguments ->
            commands.add(arguments.toList())
            if ("copy" in arguments) writeFlacHeader(output)
            true to ""
        }, {})
        assertEquals(2, commands.size)
        assertTrue("copy" in commands.first())
        assertFalse("-map" in commands.first())
        assertTrue("null" in commands.last())
        assertFalse("-frames:a" in commands.last())
        assertFalse(commands.any { "-compression_level" in it })
        assertTrue(output.exists())
    }

    @Test
    fun failedRemuxOrValidationRetriesEncoderWithCleanStage() {
        for (failure in listOf("command", "header", "decode")) {
            withFiles { input, output ->
                var encoded = false
                convertToStagedFlac(input.path, output.path, "flac", { arguments ->
                    when {
                        "copy" in arguments -> {
                            if (failure == "header") output.writeText("invalid FLAC") else writeFlacHeader(output)
                            (failure != "command") to "remux diagnostic"
                        }
                        "-compression_level" in arguments -> {
                            assertFalse(output.exists())
                            encoded = true
                            writeFlacHeader(output)
                            true to ""
                        }
                        else -> (encoded || failure != "decode") to "decode diagnostic"
                    }
                }, {})
                assertTrue(encoded)
                assertTrue(output.exists())
            }
        }
    }

    @Test
    fun nonFlacSkipsRemuxAndFailedEncodeRemovesPartialOutput() = withFiles { input, output ->
        var calls = 0
        assertThrows(IllegalStateException::class.java) {
            convertToStagedFlac(input.path, output.path, "alac", { arguments ->
                calls++
                assertFalse("copy" in arguments)
                output.writeText("partial")
                false to "encoder failed"
            }, {})
        }
        assertEquals(1, calls)
        assertFalse(output.exists())
    }

    @Test
    fun cancellationAfterRemuxDoesNotFallbackAndRemovesPartialOutput() = withFiles { input, output ->
        var cancelled = false
        var calls = 0
        assertThrows(CancellationException::class.java) {
            convertToStagedFlac(input.path, output.path, "flac", {
                calls++
                writeFlacHeader(output)
                cancelled = true
                false to "cancelled"
            }, {
                if (cancelled) throw CancellationException()
            })
        }
        assertEquals(1, calls)
        assertFalse(output.exists())
    }

    @Test
    fun hostFlacInMp4RemuxAndFallbackPreserveDecodedPcmAndArtwork() {
        val ffmpeg = System.getenv("SPOTIFLAC_TEST_FFMPEG").orEmpty()
        assumeTrue(
            "Set SPOTIFLAC_TEST_FFMPEG for host media fixtures",
            File(ffmpeg).isFile && File(ffmpeg).canExecute(),
        )
        fun execute(arguments: Array<String>): Pair<Boolean, String> {
            val process = ProcessBuilder(listOf(ffmpeg) + arguments).redirectErrorStream(true).start()
            val output = process.inputStream.bufferedReader().use { it.readText() }
            return (process.waitFor() == 0) to output
        }
        fun run(vararg arguments: String): String {
            val result = execute(arrayOf(*arguments))
            assertTrue(result.second, result.first)
            return result.second.trim()
        }
        val directory = Files.createTempDirectory("native-flac-fixture-").toFile()
        try {
            val cover = File(directory, "cover.png")
            run("-v", "error", "-f", "lavfi", "-i", "color=c=red:s=32x32", "-frames:v", "1", cover.path)
            val coverHash = run("-v", "error", "-i", cover.path, "-map", "0:v:0", "-f", "hash", "-hash", "sha256", "-")
            for ((sampleRate, sampleFormat) in listOf(44100 to "s16", 96000 to "s32")) {
                val source = File(directory, "source-$sampleRate.flac")
                val input = File(directory, "input-$sampleRate.m4a")
                run(
                    "-v", "error", "-f", "lavfi", "-i", "aevalsrc=0.1*sin(2*PI*997*t):s=$sampleRate",
                    "-t", "0.2", "-c:a", "flac", "-sample_fmt", sampleFormat, source.path,
                )
                run(
                    "-v", "error", "-i", source.path, "-i", cover.path, "-map", "0:a:0", "-map", "1:v:0",
                    "-c", "copy", "-disposition:v", "attached_pic", "-strict", "-2", "-f", "mp4", input.path,
                )
                val sourceHash = run("-v", "error", "-i", source.path, "-map", "0:a:0", "-c:a", "pcm_s32le", "-f", "hash", "-hash", "sha256", "-")
                for (mode in listOf("remux", "failed-remux", "corrupt-remux")) {
                    val output = File(directory, "output-$sampleRate-$mode.partial.flac")
                    var encoded = false
                    convertToStagedFlac(input.path, output.path, "flac", { arguments ->
                        if ("-compression_level" in arguments) encoded = true
                        if (mode == "failed-remux" && "copy" in arguments) {
                            false to "forced remux failure"
                        } else {
                            execute(arguments).also { result ->
                                if (mode == "corrupt-remux" && "copy" in arguments && result.first) {
                                    val bytes = output.readBytes()
                                    // FLAC metadata (including the cover picture) has variable size.
                                    // Locate the first audio frame instead of assuming audio lives
                                    // at a fixed offset from the end of the file.
                                    var offset = 4 // "fLaC" marker
                                    var lastMetadataBlock = false
                                    while (!lastMetadataBlock && offset + 4 <= bytes.size) {
                                        val header = bytes[offset].toInt() and 0xff
                                        lastMetadataBlock = (header and 0x80) != 0
                                        val blockLength =
                                            ((bytes[offset + 1].toInt() and 0xff) shl 16) or
                                            ((bytes[offset + 2].toInt() and 0xff) shl 8) or
                                            (bytes[offset + 3].toInt() and 0xff)
                                        offset += 4 + blockLength
                                    }
                                    check(lastMetadataBlock && offset < bytes.size) {
                                        "FLAC output has no audio frame to corrupt"
                                    }
                                    check(bytes.size - offset > 32) {
                                        "FLAC audio payload is unexpectedly short"
                                    }
                                    // Break the first frame's sync code so the validation decoder
                                    // must reject the remux instead of relying on version-specific
                                    // handling of damaged compressed sample data.
                                    bytes[offset] = (bytes[offset].toInt() xor 0xff).toByte()
                                    output.writeBytes(bytes)
                                }
                            }
                        }
                    }, {})
                    assertEquals("unexpected encoder fallback for $sampleRate Hz ($mode)", mode != "remux", encoded)
                    val outputHash = run("-v", "error", "-i", output.path, "-map", "0:a:0", "-c:a", "pcm_s32le", "-f", "hash", "-hash", "sha256", "-")
                    println("FLAC fixture $sampleRate Hz ($mode): encoded=$encoded sourcePCM=$sourceHash outputPCM=$outputHash")
                    assertEquals("decoded PCM changed for $sampleRate Hz ($mode): source=$sourceHash output=$outputHash", sourceHash, outputHash)
                    val outputCoverHash = run("-v", "error", "-i", output.path, "-map", "0:v:0", "-f", "hash", "-hash", "sha256", "-")
                    assertEquals("artwork changed for $sampleRate Hz ($mode)", coverHash, outputCoverHash)
                    assertTrue(input.exists())
                }
            }
        } finally {
            directory.deleteRecursively()
        }
    }
}
