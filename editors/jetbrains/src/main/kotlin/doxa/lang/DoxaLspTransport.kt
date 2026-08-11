package doxa.lang

import com.intellij.openapi.diagnostic.Logger
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.CopyOnWriteArrayList

class DoxaLspTransport(
    private val input: InputStream,
    private val output: OutputStream,
) {
    private val listeners = CopyOnWriteArrayList<(String) -> Unit>()
    private var running = false
    private var thread: Thread? = null

    fun start() {
        if (running) return
        running = true
        thread = Thread(::readLoop, "DoxaLspTransport").also { it.isDaemon = true; it.start() }
    }

    fun stop() {
        running = false
        thread?.interrupt()
    }

    fun addListener(listener: (String) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (String) -> Unit) {
        listeners.remove(listener)
    }

    @Synchronized
    fun send(message: String) {
        if (!running) return
        val body = message.toByteArray(Charsets.UTF_8)
        val header = "Content-Length: ${body.size}\r\n\r\n"
        try {
            output.write(header.toByteArray(Charsets.UTF_8))
            output.write(body)
            output.flush()
        } catch (e: Exception) {
            LOG.warn("Failed to send LSP message", e)
        }
    }

    private fun readLoop() {
        val buffer = ByteArray(4096)
        val content = StringBuilder()
        var contentLength = -1
        var headerDone = false
        val headerBuffer = StringBuilder()

        try {
            while (running) {
                val n = input.read(buffer)
                if (n < 0) break

                val chunk = String(buffer, 0, n, Charsets.UTF_8)
                content.append(chunk)

                while (true) {
                    if (!headerDone) {
                        val termIdx = content.indexOf("\r\n\r\n")
                        if (termIdx < 0) break

                        val header = content.substring(0, termIdx)
                        content.delete(0, termIdx + 4)

                        val prefix = "Content-Length: "
                        val startIdx = header.indexOf(prefix)
                        if (startIdx >= 0) {
                            val lenStart = startIdx + prefix.length
                            contentLength = header.substring(lenStart).trim().toIntOrNull() ?: -1
                        }
                        headerDone = true
                    }

                    if (headerDone && contentLength > 0) {
                        if (content.length < contentLength) break

                        val body = content.substring(0, contentLength)
                        content.delete(0, contentLength)
                        headerDone = false
                        contentLength = -1

                        for (listener in listeners) {
                            try {
                                listener(body)
                            } catch (e: Exception) {
                                LOG.warn("Error in LSP message listener", e)
                            }
                        }
                    } else {
                        break
                    }
                }
            }
        } catch (e: InterruptedException) {
        } catch (e: Exception) {
            if (running) LOG.warn("Transport read error", e)
        } finally {
            running = false
        }
    }

    companion object {
        private val LOG = Logger.getInstance(DoxaLspTransport::class.java)
    }
}
