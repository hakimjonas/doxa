package doxa.lang

import com.google.gson.Gson
import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.openapi.application.ApplicationManager
import com.intellij.codeInsight.daemon.DaemonCodeAnalyzer
import com.intellij.openapi.diagnostic.Logger
import com.intellij.openapi.project.Project
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger

class DoxaLspConnector(private val project: Project) {
    private var process: Process? = null
    private var transport: DoxaLspTransport? = null
    private val pendingRequests = ConcurrentHashMap<Int, CompletableFuture<String>>()
    private val notificationHandlers = ConcurrentHashMap<String, (Map<String, Any?>) -> Unit>()
    private val diagnostics = ConcurrentHashMap<String, List<Map<String, Any?>>>()
    private val documentFeatures = ConcurrentHashMap<String, DocumentFeatures>()
    private val pendingNotifications = ConcurrentLinkedQueue<Pair<String, Any?>>()
    private val unsupportedMethods = ConcurrentHashMap.newKeySet<String>()
    private val featureRefreshes = ConcurrentHashMap<String, ScheduledFuture<*>>()
    private val scheduler = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "DoxaLspFeatureRefresh").also { it.isDaemon = true }
    }
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
                val binaryPath = resolveBinaryPath()
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
                openDocumentTexts.forEach { (uri, text) ->
                    refreshDocumentFeatures(uri, documentVersions[uri]?.get() ?: 1, text)
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

    data class DocumentFeatures(
        val version: Int,
        val semanticTokens: Map<String, Any?>? = null,
        val foldingRanges: List<Any?>? = null,
        val symbols: List<Any?>? = null,
        val inlayHints: List<Any?>? = null,
    )

    fun featuresFor(uri: String): DocumentFeatures? = documentFeatures[uri]

    fun documentVersion(uri: String): Int? = documentVersions[uri]?.get()

    fun sendRequestAsync(method: String, params: Any?, timeoutSeconds: Long = 5, callback: (Any?) -> Unit): Future<*> {
        return executor.submit {
            try {
                val result = sendRequestBlocking(method, params, timeoutSeconds)
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
                val error = parsed["error"] as? Map<*, *>
                if ((error?.get("code") as? Number)?.toInt() == -32601) {
                    unsupportedMethods.add(method)
                }
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
    private val openDocumentTexts = ConcurrentHashMap<String, String>()
    private val documentVersions = ConcurrentHashMap<String, AtomicInteger>()

    fun didOpen(uri: String, text: String) {
        if (openFiles.putIfAbsent(uri, true) != null) return
        openDocumentTexts[uri] = text
        documentVersions[uri] = AtomicInteger(1)
        sendNotification("textDocument/didOpen", mapOf(
            "textDocument" to mapOf(
                "uri" to uri,
                "languageId" to "doxa",
                "version" to 1,
                "text" to text,
            ),
        ))
        refreshDocumentFeatures(uri, 1, text)
    }

    fun didChange(uri: String, text: String) {
        if (!openFiles.containsKey(uri)) {
            didOpen(uri, text)
            return
        }
        openDocumentTexts[uri] = text
        val version = documentVersions.computeIfAbsent(uri) { AtomicInteger(1) }.incrementAndGet()
        sendNotification("textDocument/didChange", mapOf(
            "textDocument" to mapOf("uri" to uri, "version" to version),
            "contentChanges" to listOf(mapOf("text" to text)),
        ))
        scheduleFeatureRefresh(uri, version, text)
    }

    /** Ensure the server knows about this file before querying. */
    fun ensureFileSent(uri: String, text: String) {
        if (!openFiles.containsKey(uri)) {
            didOpen(uri, text)
        }
    }

    fun didClose(uri: String) {
        openFiles.remove(uri)
        openDocumentTexts.remove(uri)
        documentVersions.remove(uri)
        diagnostics.remove(uri)
        documentFeatures.remove(uri)
        featureRefreshes.remove(uri)?.cancel(false)
        sendNotification("textDocument/didClose", mapOf(
            "textDocument" to mapOf("uri" to uri),
        ))
    }

    private fun scheduleFeatureRefresh(uri: String, version: Int, text: String) {
        featureRefreshes.remove(uri)?.cancel(false)
        featureRefreshes[uri] = scheduler.schedule(
            { refreshDocumentFeatures(uri, version, text) },
            300,
            TimeUnit.MILLISECONDS,
        )
    }

    private fun refreshDocumentFeatures(uri: String, version: Int, text: String) {
        if (!isRunning) return
        val range = mapOf(
            "start" to mapOf("line" to 0, "character" to 0),
            "end" to mapOf("line" to text.count { it == '\n' } + 1, "character" to 0),
        )
        requestDocumentFeature(
            uri,
            version,
            "textDocument/semanticTokens/full",
            mapOf("textDocument" to mapOf("uri" to uri)),
        )

        // Highlighting and diagnostics are visible immediately. Folding,
        // symbols, and hints are presentation details, so do not make the
        // editor wait for them after opening a file.
        scheduler.schedule({
            val requests = mutableListOf<Pair<String, Any?>>(
                "textDocument/foldingRange" to mapOf("textDocument" to mapOf("uri" to uri)),
                "textDocument/documentSymbol" to mapOf("textDocument" to mapOf("uri" to uri)),
            )
        if (serverCapabilities?.get("inlayHintProvider") == true && !unsupportedMethods.contains("textDocument/inlayHint")) {
            requests.add("textDocument/inlayHint" to mapOf("textDocument" to mapOf("uri" to uri), "range" to range))
        }
        requests.removeIf { unsupportedMethods.contains(it.first) }
        requests.forEach { (method, params) ->
            requestDocumentFeature(uri, version, method, params)
        }
        }, 200, TimeUnit.MILLISECONDS)
    }

    private fun requestDocumentFeature(uri: String, version: Int, method: String, params: Any?) {
        if (unsupportedMethods.contains(method)) return
        sendRequestAsync(method, params) { result ->
            if (documentVersions[uri]?.get() != version) return@sendRequestAsync
            documentFeatures.compute(uri) { _, current ->
                val features = current?.takeIf { it.version == version } ?: DocumentFeatures(version)
                when (method) {
                    "textDocument/semanticTokens/full" -> features.copy(semanticTokens = result as? Map<String, Any?>)
                    "textDocument/foldingRange" -> features.copy(foldingRanges = result as? List<Any?>)
                    "textDocument/documentSymbol" -> features.copy(symbols = result as? List<Any?>)
                    "textDocument/inlayHint" -> features.copy(inlayHints = result as? List<Any?>)
                    else -> features
                }
            }
            if (method == "textDocument/semanticTokens/full") {
                DaemonCodeAnalyzer.getInstance(project).restart()
            }
        }
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

    private fun resolveBinaryPath(): String {
        val configured = DoxaSettings.instance.binaryPath
        if (configured.isNotEmpty()) return configured

        val home = System.getProperty("user.home")
        val localBinary = Path.of(home, ".local", "bin", "doxa")
        if (Files.isExecutable(localBinary)) return localBinary.toString()

        val pubCacheBinary = Path.of(home, ".pub-cache", "bin", "doxa")
        if (Files.isExecutable(pubCacheBinary)) return pubCacheBinary.toString()

        return "doxa"
    }

    companion object {
        private object NullResult
        private val LOG = Logger.getInstance(DoxaLspConnector::class.java)
        private val gson = Gson()

        fun getInstance(project: Project): DoxaLspConnector? =
            project.getService(DoxaLspService::class.java)?.connector
    }
}
