package doxa.lang

import com.intellij.formatting.service.AsyncDocumentFormattingService
import com.intellij.formatting.service.AsyncFormattingRequest
import com.intellij.formatting.service.FormattingService
import com.intellij.psi.PsiFile
import java.util.concurrent.Future

class DoxaFormattingService : AsyncDocumentFormattingService() {

    override fun getNotificationGroupId(): String = "doxa.formatting"
    override fun getName(): String = "Doxa Formatter"

    override fun getFeatures(): MutableSet<FormattingService.Feature> =
        mutableSetOf()

    override fun canFormat(file: PsiFile): Boolean =
        file.language is DoxaLanguage

    override fun createFormattingTask(request: AsyncFormattingRequest): FormattingTask {
        return object : FormattingTask {
            private var requestFuture: Future<*>? = null

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

                requestFuture = connector.sendRequestAsync("textDocument/formatting", params) { response ->
                    val edits = response as? List<*> ?: return@sendRequestAsync
                    val edit = edits.firstOrNull() as? Map<*, *> ?: return@sendRequestAsync
                    val newText = edit["newText"] as? String ?: return@sendRequestAsync
                    request.onTextReady(newText)
                }
            }

            override fun cancel(): Boolean = requestFuture?.cancel(true) ?: true
            override fun isRunUnderProgress(): Boolean = true
        }
    }
}
