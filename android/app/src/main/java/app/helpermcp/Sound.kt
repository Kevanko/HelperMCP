package app.helpermcp

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.sin

/** soft bells made on the fly (the same two as on the PC): "ask" = a question is waiting, "ok" = connected */
object Sound {
    private const val SR = 22050
    private val NOTES = mapOf(
        "ask" to listOf(Triple(784.0, 0.0, 0.55), Triple(1046.5, 0.16, 0.7)),
        "ok" to listOf(Triple(523.25, 0.0, 0.5), Triple(659.25, 0.12, 0.5), Triple(783.99, 0.24, 0.7)))

    fun play(kind: String) {
        val notes = NOTES[kind] ?: return
        Thread {
            try {
                val total = notes.maxOf { it.second + it.third } + 0.1
                val buf = DoubleArray((SR * total).toInt())
                for ((f, start, dur) in notes) {
                    val i0 = (start * SR).toInt()
                    for (i in 0 until (dur * SR).toInt()) {
                        val t = i.toDouble() / SR; val env = (1 - exp(-t * 400)) * exp(-t * 5.5)
                        if (i0 + i < buf.size) buf[i0 + i] += 0.5 * env * (sin(2 * PI * f * t) + 0.28 * sin(4 * PI * f * t) + 0.08 * sin(2 * PI * 3.01 * f * t))
                    }
                }
                val pcm = ShortArray(buf.size) { (buf[it] * 22000).coerceIn(-32000.0, 32000.0).toInt().toShort() }
                val track = AudioTrack.Builder()
                    .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                    .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(SR).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                    .setBufferSizeInBytes(pcm.size * 2).setTransferMode(AudioTrack.MODE_STATIC).build()
                track.write(pcm, 0, pcm.size); track.play()
                Thread.sleep((total * 1000).toLong() + 300); track.release()
            } catch (_: Throwable) { }
        }.start()
    }
}
