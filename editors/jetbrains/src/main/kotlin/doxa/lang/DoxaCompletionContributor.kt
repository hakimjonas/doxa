package doxa.lang

import com.intellij.codeInsight.completion.*
import com.intellij.codeInsight.lookup.LookupElementBuilder
import com.intellij.patterns.PlatformPatterns
import com.intellij.psi.PsiFile
import com.intellij.util.ProcessingContext

class DoxaCompletionContributor : CompletionContributor() {
    init {
        extend(
            CompletionType.BASIC,
            PlatformPatterns.psiElement().withLanguage(DoxaLanguage.INSTANCE),
            DoxaCompletionProvider(),
        )
    }
}

class DoxaCompletionProvider : CompletionProvider<CompletionParameters>() {

    override fun addCompletions(
        parameters: CompletionParameters,
        context: ProcessingContext,
        result: CompletionResultSet,
    ) {
        val file = parameters.originalFile
        val connector = DoxaLspService.getInstance(file.project).connector
        if (!connector.isRunning) return

        val virtualFile = file.virtualFile ?: return
        val uri = virtualFile.url
        val document = file.viewProvider.document ?: return
        connector.ensureFileSent(uri, document.text)
        val offset = parameters.offset
        val position = DoxaDocumentationProvider.positionAt(document.text, offset)

        val params = mapOf(
            "textDocument" to mapOf("uri" to uri),
            "position" to mapOf("line" to position.first, "character" to position.second),
        )

        try {
            val response = connector.sendRequestBlocking("textDocument/completion", params)
            val items = response["items"] as? List<*> ?: return
            for (item in items) {
                val i = item as? Map<*, *> ?: continue
                val label = i["label"] as? String ?: continue
                val detail = i["detail"] as? String
                val documentation = i["documentation"] as? String

                val builder = LookupElementBuilder.create(label)
                    .withTypeText(detail ?: "")
                if (documentation != null) {
                    builder.withTailText(" — $documentation", true)
                }
                result.addElement(builder)
            }
        } catch (_: Exception) {
        }
    }
}
