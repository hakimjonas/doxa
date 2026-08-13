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
    private val keywords = listOf(
        "val", "fun", "data", "type", "match", "case", "returning",
        "import", "opaque", "rec", "struct", "where", "theorem", "with", "ind",
    )

    override fun addCompletions(
        parameters: CompletionParameters,
        context: ProcessingContext,
        result: CompletionResultSet,
    ) {
        val file = parameters.originalFile
        val service = DoxaLspService.getInstance(file.project)
        if (!service.connector.isRunning) return

        val virtualFile = file.virtualFile ?: return
        val uri = virtualFile.url
        val document = file.viewProvider.document ?: return
        val offset = parameters.offset
        val response = service.completionAt(uri, document.text, offset)
        if (response == null) {
            keywords.forEach { result.addElement(LookupElementBuilder.create(it)) }
            return
        }
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
    }
}
