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
    private val diagnostics = ConcurrentHashMap<String, List<Map<String, Any?>>>()
    private val pendingNotifications = ConcurrentLinkedQueue<Pair<String, Any?>>()
    private val requestId = AtomicInteger(0)
    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "DoxaLspConnector").also { it.isDaemon = true }
    }
    @Volatile
    var isRunning = false
        private set
    @Volatile
    private var isStarting = false

    @Volatile
    var serverCapabilities: Map<String, Any?>? = null
        private set

    @Synchronized
    fun start() {
        if (isRunning || isStarting) return
        isStarting = true
        LOG.info("Starting Doxa language server...")

        executor.submit {
            try {
                val binaryPath = DoxaSettings.instance.binaryPath.ifEmpty { "doxa" }
                LOG.info("Spawning: $binaryPath lsp")
                val commandLine = GeneralCommandLine(binaryPath, "lsp")
                    .withParentEnvironmentType(GeneralCommandLine.ParentEnvironmentType.CONSOLE)

                process = commandLine.createProcess()
                val startedProcess = process!!
                startedProcess.onExit().thenRun {
                    if (process === startedProcess && isRunning) {
                        isRunning = false
                        transport?.stop()
                        transport = null
                        process = null
                        pendingRequests.values.forEach { it.cancel(true) }
                        pendingRequests.clear()
                        DoxaNotifications.serverError(project, "The Doxa language server stopped unexpectedly. Open a Doxa file to restart it.")
                    }
                }
                LOG.info("Server process started, setting up transport")
                val t = DoxaLspTransport(process!!.inputStream, process!!.outputStream)
                transport = t
                t.addListener { message -> handleMessage(message) }
                t.start()

                val result = sendRequestBlocking("initialize", mapOf(
                    "processId" to ProcessHandle.current().pid(),
                    "rootUri" to null,
                    "capabilities" to emptyMap<String, Any>(),
                ))
                serverCapabilities = (result as? Map<*, *>)?.get("capabilities") as? Map<String, Any?>
                LOG.info("Server initialized, caps: ${serverCapabilities?.keys?.joinToString()}")

                sendNotificationDirect("initialized", emptyMap<String, Any>())
                sendNotificationDirect("workspace/didChangeConfiguration", mapOf(
                    "settings" to emptyMap<String, Any>(),
                ))
                isRunning = true
                isStarting = false
                while (true) {
                    val notification = pendingNotifications.poll() ?: break
                    sendNotificationDirect(notification.first, notification.second)
                }
                LOG.info("Doxa LSP server ready")
            } catch (e: Exception) {
                LOG.warn("Failed to start Doxa language server", e)
                isRunning = false
                isStarting = false
                DoxaNotifications.serverError(
                    project,
                    "Could not start Doxa. Configure a valid Doxa executable in Settings | Languages & Frameworks | Doxa.",
                )
            }
        }
    }

    @Synchronized
    fun stop() {
        if (!isRunning && !isStarting) return
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
            pendingNotifications.clear()
        }
        isRunning = false
        isStarting = false
    }

    fun restart() {
        stop()
        start()
    }

    fun onNotification(method: String, handler: (Map<String, Any?>) -> Unit) {
        notificationHandlers[method] = handler
    }

    fun diagnosticsFor(uri: String): List<Map<String, Any?>> = diagnostics[uri].orEmpty()

    fun sendRequestAsync(method: String, params: Any?, callback: (Any?) -> Unit): Future<*> {
        return executor.submit {
            try {
                val result = sendRequestBlocking(method, params)
                ApplicationManager.getApplication().invokeLater {
                    callback(result)
                }
            } catch (e: Exception) {
                LOG.warn("LSP request failed: $method", e)
                ApplicationManager.getApplication().invokeLater {
                    callback(null)
                }
            }
        }
    }

    fun sendRequestBlocking(method: String, params: Any?, timeoutSeconds: Long = 5): Any? {
        val id = requestId.incrementAndGet()
        val future = CompletableFuture<String>()
        pendingRequests[id] = future

        val message = buildJsonRpcRequest(id, method, params)
        val currentTransport = transport ?: run {
            pendingRequests.remove(id)
            return null
        }
        currentTransport.send(message)

        return try {
            val response = future.get(timeoutSeconds, TimeUnit.SECONDS)
            val parsed = gson.fromJson(response, Map::class.java) as Map<String, Any?>
            if (parsed.containsKey("error")) {
                LOG.warn("LSP request failed: $method: ${parsed["error"]}")
                null
            } else {
                parsed["result"]
            }
        } catch (e: Exception) {
            pendingRequests.remove(id)
            LOG.warn("LSP request timeout or error: $method", e)
            null
        }
    }

    fun cancelRequest(id: Int) {
        pendingRequests.remove(id)?.cancel(true)
        sendNotification("\$/cancelRequest", mapOf("id" to id))
    }

    fun sendNotification(method: String, params: Any?) {
        if (!isRunning) {
            pendingNotifications.add(method to params)
            return
        }
        sendNotificationDirect(method, params)
    }

    private fun sendNotificationDirect(method: String, params: Any?) {
        val message = buildJsonRpcNotification(method, params)
        transport?.send(message)
    }

    private val openFiles = ConcurrentHashMap<String, Boolean>()
    private val documentVersions = ConcurrentHashMap<String, AtomicInteger>()

    fun didOpen(uri: String, text: String) {
        if (openFiles.putIfAbsent(uri, true) != null) return
        documentVersions[uri] = AtomicInteger(1)
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
        if (!openFiles.containsKey(uri)) {
            didOpen(uri, text)
            return
        }
        val version = documentVersions.computeIfAbsent(uri) { AtomicInteger(1) }.incrementAndGet()
        sendNotification("textDocument/didChange", mapOf(
            "textDocument" to mapOf("uri" to uri, "version" to version),
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
        openFiles.remove(uri)
        documentVersions.remove(uri)
        diagnostics.remove(uri)
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
            if (method == "textDocument/publishDiagnostics" && params != null) {
                val uri = params["uri"] as? String
                val items = params["diagnostics"] as? List<*>
                if (uri != null && items != null) {
                    diagnostics[uri] = items.mapNotNull { it as? Map<String, Any?> }
                }
            }
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
