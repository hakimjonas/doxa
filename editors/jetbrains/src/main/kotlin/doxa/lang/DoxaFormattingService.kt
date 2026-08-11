package doxa.lang

import com.intellij.formatting.service.AsyncDocumentFormattingService
import com.intellij.formatting.service.AsyncFormattingRequest
import com.intellij.formatting.service.FormattingService
import com.intellij.psi.PsiFile

class DoxaFormattingService : AsyncDocumentFormattingService() {

    override fun getNotificationGroupId(): String = "doxa.formatting"
    override fun getName(): String = "Doxa Formatter"

    override fun getFeatures(): MutableSet<FormattingService.Feature> =
        mutableSetOf(FormattingService.Feature.FORMAT_FRAGMENTS)

    override fun canFormat(file: PsiFile): Boolean =
        file.language is DoxaLanguage

    override fun createFormattingTask(request: AsyncFormattingRequest): FormattingTask {
        return object : FormattingTask {
            override fun run() {
                val virtualFile = request.context.virtualFile ?: return
                val uri = virtualFile.url
                val text = request.documentText
                val project = request.context.project ?: return

                val connector = DoxaLspService.getInstance(project).connector
                if (!connector.isRunning) return

                connector.ensureFileSent(uri, text)

                val params = mapOf(
                    "textDocument" to mapOf("uri" to uri),
                    "options" to mapOf("tabSize" to 2, "insertSpaces" to true),
                )

                try {
                    val response = connector.sendRequestBlocking("textDocument/formatting", params)
                    val edits = response as? List<*> ?: return
                    if (edits.isEmpty()) return
                    val edit = edits[0] as? Map<*, *> ?: return
                    val newText = edit["newText"] as? String ?: return
                    request.onTextReady(newText)
                } catch (_: Exception) {
                }
            }

            override fun cancel(): Boolean { return true }
            override fun isRunUnderProgress(): Boolean = true
        }
    }
}
