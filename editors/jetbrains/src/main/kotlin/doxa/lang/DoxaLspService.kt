package doxa.lang

import com.intellij.openapi.components.Service
import com.intellij.openapi.Disposable
import com.intellij.openapi.editor.Document
import com.intellij.openapi.editor.EditorFactory
import com.intellij.openapi.editor.event.DocumentEvent
import com.intellij.openapi.editor.event.DocumentListener
import com.intellij.openapi.fileEditor.FileDocumentManager
import com.intellij.openapi.fileEditor.FileEditorManager
import com.intellij.openapi.fileEditor.FileEditorManagerListener
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.VirtualFile

@Service(Service.Level.PROJECT)
class DoxaLspService(val project: Project) : Disposable {
    val connector = DoxaLspConnector(project)

    init {
        EditorFactory.getInstance().eventMulticaster.addDocumentListener(object : DocumentListener {
            override fun documentChanged(event: DocumentEvent) {
                syncDocument(event.document)
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
        connector.didChange(file.url, document.text)
    }

    private fun syncFile(file: VirtualFile) {
        if (file.extension != "doxa") return
        val document = FileDocumentManager.getInstance().getDocument(file) ?: return
        connector.didOpen(file.url, document.text)
    }

    override fun dispose() {
        connector.stop()
    }

    companion object {
        fun getInstance(project: Project): DoxaLspService =
            project.getService(DoxaLspService::class.java)
    }
}
