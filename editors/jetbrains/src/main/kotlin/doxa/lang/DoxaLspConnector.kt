package doxa.lang

import com.google.gson.Gson
import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.diagnostic.Logger
import com.intellij.openapi.project.Project
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger

class DoxaLspConnector(private val project: Project) {
    private var process: Process? = null
    private var transport: DoxaLspTransport? = null
    private val pendingRequests = ConcurrentHashMap<Int, CompletableFuture<String>>()
    private val notificationHandlers = ConcurrentHashMap<String, (Map<String, Any?>) -> Unit>()
    private val requestId = AtomicInteger(0)
    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "DoxaLspConnector").also { it.isDaemon = true }
    }
    @Volatile
    var isRunning = false
        private set

    @Volatile
    var serverCapabilities: Map<String, Any?>? = null
        private set

    fun start() {
        if (isRunning) return
        isRunning = true

        executor.submit {
            try {
                val binaryPath = DoxaSettings.instance.binaryPath.ifEmpty { "doxa" }
                val commandLine = GeneralCommandLine(binaryPath, "lsp")
                    .withParentEnvironmentType(GeneralCommandLine.ParentEnvironmentType.CONSOLE)

                process = commandLine.createProcess()
                val t = DoxaLspTransport(process!!.inputStream, process!!.outputStream)
                transport = t
                t.addListener { message -> handleMessage(message) }
                t.start()

                val result = sendRequestBlocking("initialize", mapOf(
                    "processId" to ProcessHandle.current().pid(),
                    "rootUri" to null,
                    "capabilities" to emptyMap<String, Any>(),
                ))
                serverCapabilities = (result["capabilities"] as? Map<String, Any?>)

                sendNotification("initialized", emptyMap<String, Any>())
                sendNotification("workspace/didChangeConfiguration", mapOf(
                    "settings" to emptyMap<String, Any>(),
                ))
            } catch (e: Exception) {
                LOG.warn("Failed to start Doxa language server", e)
                isRunning = false
            }
        }
    }

    fun stop() {
        if (!isRunning) return
        executor.submit {
            try {
                sendRequestBlocking("shutdown", emptyMap<String, Any>())
                sendNotification("exit", emptyMap<String, Any>())
            } catch (_: Exception) {
            }
            transport?.stop()
            process?.destroyForcibly()
            transport = null
            process = null
            pendingRequests.clear()
        }
        isRunning = false
        executor.shutdown()
    }

    fun onNotification(method: String, handler: (Map<String, Any?>) -> Unit) {
        notificationHandlers[method] = handler
    }

    fun sendRequestAsync(method: String, params: Any?, callback: (Map<String, Any?>) -> Unit) {
        executor.submit {
            try {
                val result = sendRequestBlocking(method, params)
                ApplicationManager.getApplication().invokeLater {
                    callback(result)
                }
            } catch (e: Exception) {
                LOG.warn("LSP request failed: $method", e)
                ApplicationManager.getApplication().invokeLater {
                    callback(emptyMap())
                }
            }
        }
    }

    fun sendRequestBlocking(method: String, params: Any?): Map<String, Any?> {
        val id = requestId.incrementAndGet()
        val future = CompletableFuture<String>()
        pendingRequests[id] = future

        val message = buildJsonRpcRequest(id, method, params)
        transport?.send(message)

        return try {
            val response = future.get(30, TimeUnit.SECONDS)
            val parsed = gson.fromJson(response, Map::class.java) as Map<String, Any?>
            (parsed["result"] as? Map<String, Any?>) ?: emptyMap()
        } catch (e: Exception) {
            pendingRequests.remove(id)
            LOG.warn("LSP request timeout or error: $method", e)
            emptyMap()
        }
    }

    fun sendNotification(method: String, params: Any?) {
        val message = buildJsonRpcNotification(method, params)
        transport?.send(message)
    }

    private val openFiles = ConcurrentHashMap<String, Boolean>()

    fun didOpen(uri: String, text: String) {
        openFiles[uri] = true
        sendNotification("textDocument/didOpen", mapOf(
            "textDocument" to mapOf(
                "uri" to uri,
                "languageId" to "doxa",
                "version" to 1,
                "text" to text,
            ),
        ))
    }

    fun didChange(uri: String, text: String) {
        openFiles.putIfAbsent(uri, false)
        sendNotification("textDocument/didChange", mapOf(
            "textDocument" to mapOf("uri" to uri, "version" to 1),
            "contentChanges" to listOf(mapOf("text" to text)),
        ))
    }

    /** Ensure the server knows about this file before querying. */
    fun ensureFileSent(uri: String, text: String) {
        if (openFiles.putIfAbsent(uri, true) == null) {
            didOpen(uri, text)
        }
    }

    fun didClose(uri: String) {
        sendNotification("textDocument/didClose", mapOf(
            "textDocument" to mapOf("uri" to uri),
        ))
    }

    private fun handleMessage(raw: String) {
        val message = try {
            gson.fromJson(raw, Map::class.java) as Map<String, Any?>
        } catch (e: Exception) {
            LOG.warn("Failed to parse LSP message", e)
            return
        }

        val id = (message["id"] as? Number)?.toInt()
        val method = message["method"] as? String

        if (id != null && method == null) {
            pendingRequests.remove(id)?.complete(raw)
        } else if (method != null) {
            val params = message["params"] as? Map<String, Any?>
            ApplicationManager.getApplication().invokeLater {
                notificationHandlers[method]?.invoke(params ?: emptyMap())
            }
        }
    }

    private fun buildJsonRpcRequest(id: Int, method: String, params: Any?): String {
        val msg = mutableMapOf<String, Any?>(
            "jsonrpc" to "2.0",
            "id" to id,
            "method" to method,
            "params" to params,
        )
        return gson.toJson(msg)
    }

    private fun buildJsonRpcNotification(method: String, params: Any?): String {
        val msg = mutableMapOf<String, Any?>(
            "jsonrpc" to "2.0",
            "method" to method,
            "params" to params,
        )
        return gson.toJson(msg)
    }

    companion object {
        private val LOG = Logger.getInstance(DoxaLspConnector::class.java)
        private val gson = Gson()

        fun getInstance(project: Project): DoxaLspConnector? =
            project.getService(DoxaLspService::class.java)?.connector
    }
}
