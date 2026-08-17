package doxa.lang

import com.intellij.model.Pointer
import com.intellij.platform.backend.documentation.DocumentationResult
import com.intellij.platform.backend.documentation.DocumentationTarget
import com.intellij.platform.backend.documentation.DocumentationTargetProvider
import com.intellij.platform.backend.presentation.TargetPresentation
import com.intellij.psi.PsiFile
import java.util.function.Supplier

class DoxaDocumentationProvider : DocumentationTargetProvider {
    override fun documentationTargets(file: PsiFile, offset: Int): List<DocumentationTarget> {
        if (file.language !is DoxaLanguage) return emptyList()
        val virtualFile = file.virtualFile ?: return emptyList()
        val document = file.viewProvider.document ?: return emptyList()
        return listOf(DoxaDocumentationTarget(file.project, virtualFile.url, document.text, offset))
    }

    companion object {
        fun positionAt(text: String, offset: Int): Pair<Int, Int> {
            var line = 0
            var col = 0
            for (i in 0 until offset.coerceIn(0, text.length)) {
                if (text[i] == '\n') { line++; col = 0 }
                else if (text[i] == '\r') {
                    if (i + 1 < text.length && text[i + 1] == '\n') continue
                    line++; col = 0
                } else col++
            }
            return Pair(line, col)
        }
    }
}

private class DoxaDocumentationTarget(
    private val project: com.intellij.openapi.project.Project,
    private val uri: String,
    private val text: String,
    private val offset: Int,
) : DocumentationTarget {
    override fun createPointer(): Pointer<out DocumentationTarget> = Pointer.hardPointer(this)

    override fun computePresentation(): TargetPresentation =
        TargetPresentation.builder("Doxa").presentation()

    override fun computeDocumentation(): DocumentationResult = DocumentationResult.asyncDocumentation(Supplier {
        val connector = DoxaLspService.getInstance(project).connector
        if (!connector.isRunning) return@Supplier null
        connector.ensureFileSent(uri, text)
        val position = DoxaDocumentationProvider.positionAt(text, offset)
        val response = connector.sendRequestBlocking(
            "textDocument/hover",
            mapOf(
                "textDocument" to mapOf("uri" to uri),
                "position" to mapOf("line" to position.first, "character" to position.second),
            ),
        ) as? Map<*, *> ?: return@Supplier null
        val contents = response["contents"]
        val value = when (contents) {
            is String -> contents
            is Map<*, *> -> contents["value"] as? String
            else -> null
        } ?: return@Supplier null
        DocumentationResult.documentation("<pre>${escapeHtml(value)}</pre>")
    })

    private fun escapeHtml(value: String): String = value
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
}
