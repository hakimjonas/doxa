package doxa.lang

import com.intellij.codeInsight.codeVision.*
import com.intellij.codeInsight.codeVision.ui.model.TextCodeVisionEntry
import com.intellij.openapi.editor.Editor
import com.intellij.openapi.util.TextRange
import com.intellij.psi.PsiFile

class DoxaCodeLensProvider : CodeVisionProvider<Void> {

    override val id = "doxa.codeLens"
    override val name = "Doxa Code Lens"
    override val groupId = "doxa"
    override val defaultAnchor = CodeVisionAnchorKind.Top
    override val relativeOrderings = emptyList<CodeVisionRelativeOrdering>()

    @Suppress("UNCHECKED_CAST")
    override fun precomputeOnUiThread(editor: Editor): Void = null as Void

    override fun computeForEditor(editor: Editor, uiData: Void): List<Pair<TextRange, CodeVisionEntry>> {
        val project = editor.project ?: return emptyList()
        val file = com.intellij.psi.PsiDocumentManager.getInstance(project).getPsiFile(editor.document) ?: return emptyList()
        if (file.language !is DoxaLanguage) return emptyList()

        val connector = DoxaLspService.getInstance(project).connector
        if (!connector.isRunning) return emptyList()

        val virtualFile = file.virtualFile ?: return emptyList()
        val uri = virtualFile.url

        val params = mapOf("textDocument" to mapOf("uri" to uri))
        val result = mutableListOf<Pair<TextRange, CodeVisionEntry>>()

        try {
            val response = connector.sendRequestBlocking("textDocument/codeLens", params)
            val lenses = response as? List<*> ?: return emptyList()
            val text = editor.document.text
            for (l in lenses) {
                val lens = l as? Map<*, *> ?: continue
                val range = lens["range"] as? Map<*, *> ?: continue
                val start = range["start"] as? Map<*, *> ?: continue
                val line = (start["line"] as? Number)?.toInt() ?: continue
                val character = (start["character"] as? Number)?.toInt() ?: 0
                val command = lens["command"] as? Map<*, *>
                val title = command?.get("title") as? String ?: continue
                val offset = offsetFor(text, line, character)
                result.add(
                    TextRange(offset, offset) to TextCodeVisionEntry(title, id, null, title, title, emptyList())
                )
            }
        } catch (_: Exception) {
        }
        return result
    }

    companion object {
        private fun offsetFor(text: String, line: Int, character: Int): Int {
            var cl = 0
            var off = 0
            while (off < text.length && cl < line) {
                if (text[off] == '\n') cl++
                else if (text[off] == '\r') {
                    if (off + 1 < text.length && text[off + 1] == '\n') off++
                    cl++
                }
                off++
            }
            return (off + character).coerceIn(0, text.length)
        }
    }
}
