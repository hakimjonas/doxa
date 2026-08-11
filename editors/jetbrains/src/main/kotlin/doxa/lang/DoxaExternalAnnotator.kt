package doxa.lang

import com.intellij.lang.annotation.AnnotationHolder
import com.intellij.lang.annotation.ExternalAnnotator
import com.intellij.lang.annotation.HighlightSeverity
import com.intellij.openapi.editor.Document
import com.intellij.openapi.util.TextRange
import com.intellij.psi.PsiDocumentManager
import com.intellij.psi.PsiFile

class DoxaExternalAnnotator : ExternalAnnotator<PsiFile, List<DoxaExternalAnnotator.Diag>>() {

    data class Diag(
        val range: TextRange,
        val message: String,
        val severity: Int,
    )

    override fun collectInformation(file: PsiFile): PsiFile? {
        if (file.language !is DoxaLanguage) return null
        val connector = DoxaLspService.getInstance(file.project).connector
        if (!connector.isRunning) connector.start()
        return file
    }

    override fun doAnnotate(file: PsiFile): List<Diag> {
        val virtualFile = file.virtualFile ?: return emptyList()
        val document = PsiDocumentManager.getInstance(file.project).getDocument(file) ?: return emptyList()
        val uri = virtualFile.url
        val text = document.text

        val connector = DoxaLspService.getInstance(file.project).connector
        if (!connector.isRunning) return emptyList()

        connector.didChange(uri, text)

        val diags = mutableListOf<Diag>()
        connector.onNotification("textDocument/publishDiagnostics") { params ->
            val diagUri = params["uri"] as? String
            if (diagUri == uri) {
                val items = params["diagnostics"] as? List<*> ?: emptyList<Any>()
                for (item in items) {
                    val d = item as? Map<*, *> ?: continue
                    val range = d["range"] as? Map<*, *> ?: continue
                    val start = range["start"] as? Map<*, *> ?: continue
                    val end = range["end"] as? Map<*, *> ?: continue
                    val sl = (start["line"] as? Number)?.toInt() ?: 0
                    val sc = (start["character"] as? Number)?.toInt() ?: 0
                    val el = (end["line"] as? Number)?.toInt() ?: 0
                    val ec = (end["character"] as? Number)?.toInt() ?: 0
                    val msg = d["message"] as? String ?: ""
                    val sev = (d["severity"] as? Number)?.toInt() ?: 1

                    diags.add(
                        Diag(
                            range = TextRange(offsetFor(text, sl, sc), offsetFor(text, el, ec)),
                            message = msg,
                            severity = sev,
                        )
                    )
                }
            }
        }

        Thread.sleep(500)
        return diags
    }

    override fun apply(file: PsiFile, annotationResult: List<Diag>, holder: AnnotationHolder) {
        for (diag in annotationResult) {
            val severity = when (diag.severity) {
                1 -> HighlightSeverity.ERROR
                2 -> HighlightSeverity.WARNING
                3 -> HighlightSeverity.INFORMATION
                4 -> HighlightSeverity.WEAK_WARNING
                else -> HighlightSeverity.ERROR
            }
            holder.newAnnotation(severity, diag.message)
                .range(diag.range)
                .create()
        }
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
