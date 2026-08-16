package doxa.lang

import com.intellij.openapi.components.Service
import com.intellij.openapi.Disposable
import com.intellij.codeInsight.daemon.DaemonCodeAnalyzer
import com.intellij.openapi.editor.Document
import com.intellij.openapi.editor.EditorFactory
import com.intellij.openapi.editor.event.CaretEvent
import com.intellij.openapi.editor.event.CaretListener
import com.intellij.openapi.editor.event.DocumentEvent
import com.intellij.openapi.editor.event.DocumentListener
import com.intellij.openapi.fileEditor.FileDocumentManager
import com.intellij.openapi.fileEditor.FileEditorManager
import com.intellij.openapi.fileEditor.FileEditorManagerListener
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.openapi.vfs.VirtualFileManager
import com.intellij.openapi.vfs.newvfs.BulkFileListener
import com.intellij.openapi.vfs.newvfs.events.VFileEvent
import java.util.concurrent.ConcurrentHashMap

@Service(Service.Level.PROJECT)
class DoxaLspService(val project: Project) : Disposable {
    val connector = DoxaLspConnector(project)
    private val completionCache = ConcurrentHashMap<PositionKey, Map<String, Any?>>()
    private val definitionCache = ConcurrentHashMap<PositionKey, Any?>()
    private val pendingCompletions = ConcurrentHashMap.newKeySet<PositionKey>()
    private val pendingDefinitions = ConcurrentHashMap.newKeySet<PositionKey>()

    init {
        EditorFactory.getInstance().eventMulticaster.addDocumentListener(object : DocumentListener {
            override fun documentChanged(event: DocumentEvent) {
                syncDocument(event.document)
            }
        }, this)

        EditorFactory.getInstance().eventMulticaster.addCaretListener(object : CaretListener {
            override fun caretPositionChanged(event: CaretEvent) {
                val editor = event.editor
                if (editor.project != project) return
                prefetchPositionFeatures(editor.document, editor.caretModel.offset)
            }
        }, this)

        project.messageBus.connect(this).subscribe(FileEditorManagerListener.FILE_EDITOR_MANAGER, object : FileEditorManagerListener {
            override fun fileOpened(source: FileEditorManager, file: VirtualFile) {
                syncFile(file)
            }

            override fun fileClosed(source: FileEditorManager, file: VirtualFile) {
                if (file.extension == "doxa") connector.didClose(file.url)
            }
        })

        project.messageBus.connect(this).subscribe(VirtualFileManager.VFS_CHANGES, object : BulkFileListener {
            override fun after(events: List<VFileEvent>) {
                val changes = events.mapNotNull { event ->
                    val file = event.file ?: return@mapNotNull null
                    if (file.extension != "doxa") return@mapNotNull null
                    mapOf("uri" to file.url, "type" to 2)
                }
                if (changes.isNotEmpty()) {
                    connector.sendNotification("workspace/didChangeWatchedFiles", mapOf("changes" to changes))
                }
            }
        })
    }

    fun startServer() {
        connector.start()
    }

    fun stopServer() {
        connector.stop()
    }

    fun restartServer() {
        connector.restart()
    }

    private fun syncDocument(document: Document) {
        val file = FileDocumentManager.getInstance().getFile(document) ?: return
        if (file.extension != "doxa") return
        if (FileEditorManager.getInstance(project).getAllEditors(file).isEmpty()) return
        clearPositionFeatures(file.url)
        connector.didChange(file.url, document.text)
    }

    fun completionAt(uri: String, text: String, offset: Int): Map<String, Any?>? {
        connector.ensureFileSent(uri, text)
        val key = positionKey(uri, offset) ?: return null
        requestCompletion(key, text)
        return completionCache[key]
    }

    fun definitionAt(uri: String, text: String, offset: Int): Any? {
        connector.ensureFileSent(uri, text)
        val key = positionKey(uri, offset) ?: return null
        val cached = definitionCache[key]
        if (cached != null) return cached.takeUnless { it === NoResult }
        requestDefinition(key, text)
        return null
    }

    private fun prefetchPositionFeatures(document: Document, offset: Int) {
        val file = FileDocumentManager.getInstance().getFile(document) ?: return
        if (file.extension != "doxa") return
        val key = positionKey(file.url, offset) ?: return
        requestCompletion(key, document.text)
        requestDefinition(key, document.text)
    }

    private fun positionKey(uri: String, offset: Int): PositionKey? {
        val version = connector.documentVersion(uri) ?: return null
        return PositionKey(uri, version, offset)
    }

    private fun requestCompletion(key: PositionKey, text: String) {
        if (completionCache.containsKey(key) || !pendingCompletions.add(key)) return
        connector.sendRequestAsync("textDocument/completion", positionParams(key.uri, text, key.offset)) { result ->
            (result as? Map<*, *>)?.let { completionCache[key] = it.entries.associate { it.key.toString() to it.value } }
            pendingCompletions.remove(key)
        }
    }

    private fun requestDefinition(key: PositionKey, text: String) {
        if (definitionCache.containsKey(key) || !pendingDefinitions.add(key)) return
        connector.sendRequestAsync("textDocument/definition", positionParams(key.uri, text, key.offset)) { result ->
            definitionCache[key] = result ?: NoResult
            pendingDefinitions.remove(key)
            DaemonCodeAnalyzer.getInstance(project).restart()
        }
    }

    private fun positionParams(uri: String, text: String, offset: Int): Map<String, Any> {
        val position = DoxaDocumentationProvider.positionAt(text, offset)
        return mapOf(
            "textDocument" to mapOf("uri" to uri),
            "position" to mapOf("line" to position.first, "character" to position.second),
        )
    }

    private fun syncFile(file: VirtualFile) {
        if (file.extension != "doxa") return
        val document = FileDocumentManager.getInstance().getDocument(file) ?: return
        connector.didOpen(file.url, document.text)
    }

    private fun clearPositionFeatures(uri: String) {
        completionCache.keys.removeIf { it.uri == uri }
        definitionCache.keys.removeIf { it.uri == uri }
        pendingCompletions.removeIf { it.uri == uri }
        pendingDefinitions.removeIf { it.uri == uri }
    }

    override fun dispose() {
        connector.stop()
    }

    companion object {
        private data class PositionKey(val uri: String, val version: Int, val offset: Int)
        private object NoResult
        fun getInstance(project: Project): DoxaLspService =
            project.getService(DoxaLspService::class.java)
    }
}
