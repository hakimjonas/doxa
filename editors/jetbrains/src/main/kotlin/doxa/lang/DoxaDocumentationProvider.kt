package doxa.lang

import com.intellij.lang.documentation.AbstractDocumentationProvider
import com.intellij.lang.documentation.DocumentationMarkup
import com.intellij.openapi.editor.Editor
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiFile
import com.intellij.psi.util.PsiTreeUtil

class DoxaDocumentationProvider : AbstractDocumentationProvider() {

    override fun generateDoc(element: PsiElement, originalElement: PsiElement?): String? {
        if (element.language !is DoxaLanguage) return null
        val file = element.containingFile ?: return null
        val connector = DoxaLspService.getInstance(file.project).connector
        if (!connector.isRunning) return null

        val virtualFile = file.virtualFile ?: return null
        val uri = virtualFile.url
        val document = file.viewProvider.document ?: return null
        connector.ensureFileSent(uri, document.text)
        val offset = element.textOffset
        val position = positionAt(document.text, offset)

        val params = mapOf(
            "textDocument" to mapOf("uri" to uri),
            "position" to mapOf("line" to position.first, "character" to position.second),
        )

        var result = ""
        try {
            val response = connector.sendRequestBlocking("textDocument/hover", params)
            val contents = response["contents"] as? Map<*, *>
            val value = contents?.get("value") as? String
            if (value != null) result = value
        } catch (_: Exception) {
            return null
        }

        if (result.isEmpty()) return null
        return DocumentationMarkup.CONTENT_START + result + DocumentationMarkup.CONTENT_END
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
