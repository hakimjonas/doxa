package doxa.lang

import com.intellij.lang.annotation.AnnotationHolder
import com.intellij.lang.annotation.ExternalAnnotator
import com.intellij.lang.annotation.HighlightSeverity
import com.intellij.openapi.editor.DefaultLanguageHighlighterColors
import com.intellij.openapi.editor.colors.TextAttributesKey
import com.intellij.openapi.util.TextRange
import com.intellij.psi.PsiDocumentManager
import com.intellij.psi.PsiFile

class DoxaExternalAnnotator : ExternalAnnotator<PsiFile, DoxaExternalAnnotator.AnnotatorResult>() {

    data class AnnotatorResult(
        val diagnostics: List<Diag>,
        val highlights: List<TokenHighlight>,
    )

    data class Diag(
        val range: TextRange,
        val message: String,
        val severity: Int,
    )

    data class TokenHighlight(
        val range: TextRange,
        val tokenType: String,
        val modifier: Int,
    )

    override fun collectInformation(file: PsiFile): PsiFile? {
        if (file.language !is DoxaLanguage) return null
        val connector = DoxaLspService.getInstance(file.project).connector
        if (!connector.isRunning) connector.start()
        return file
    }

    override fun doAnnotate(file: PsiFile): AnnotatorResult {
        val virtualFile = file.virtualFile ?: return AnnotatorResult(emptyList(), emptyList())
        val document = PsiDocumentManager.getInstance(file.project).getDocument(file) ?: return AnnotatorResult(emptyList(), emptyList())
        val uri = virtualFile.url
        val text = document.text

        val connector = DoxaLspService.getInstance(file.project).connector
        if (!connector.isRunning) return AnnotatorResult(emptyList(), emptyList())

        // Register listeners FIRST, then trigger didChange so we don't miss fast responses.
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

        // Now trigger the server to re-check.
        connector.didChange(uri, text)

        // Fetch semantic tokens.
        val highlights = mutableListOf<TokenHighlight>()
        try {
            val legend = (connector.serverCapabilities?.get("semanticTokensProvider") as? Map<*, *>)
                ?.get("legend") as? Map<*, *>
            val tokenTypes = legend?.get("tokenTypes") as? List<*> ?: emptyList<Any>()

            val semResponse = connector.sendRequestBlocking("textDocument/semanticTokens/full", mapOf(
                "textDocument" to mapOf("uri" to uri),
            ))
            val data = semResponse["data"] as? List<*> ?: emptyList<Any>()
            if (data.isNotEmpty()) {
                var prevLine = 0
                var prevChar = 0
                var idx = 0
                while (idx + 4 < data.size) {
                    val dLine = (data[idx++] as? Number)?.toInt() ?: 0
                    val dChar = (data[idx++] as? Number)?.toInt() ?: 0
                    val length = (data[idx++] as? Number)?.toInt() ?: 0
                    val typeIdx = (data[idx++] as? Number)?.toInt() ?: 0
                    val modBits = (data[idx++] as? Number)?.toInt() ?: 0

                    val line = prevLine + dLine
                    val char = if (dLine == 0) prevChar + dChar else dChar
                    val startOffset = offsetFor(text, line, char)
                    val endOffset = (startOffset + length).coerceAtMost(text.length)
                    val tokenType = if (typeIdx in tokenTypes.indices) tokenTypes[typeIdx] as? String ?: "" else ""

                    if (length > 0 && tokenType.isNotEmpty()) {
                        highlights.add(
                            TokenHighlight(
                                range = TextRange(startOffset, endOffset),
                                tokenType = tokenType,
                                modifier = modBits,
                            )
                        )
                    }
                    prevLine = line
                    prevChar = char
                }
            }
        } catch (_: Exception) {
        }

        Thread.sleep(300)
        return AnnotatorResult(diagnostics = diags, highlights = highlights)
    }

    override fun apply(file: PsiFile, annotationResult: AnnotatorResult, holder: AnnotationHolder) {
        for (diag in annotationResult.diagnostics) {
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

        for (hl in annotationResult.highlights) {
            val attrKey = tokenTypeToTextAttributes(hl.tokenType) ?: continue
            holder.newSilentAnnotation(HighlightSeverity.INFORMATION)
                .range(hl.range)
                .textAttributes(attrKey)
                .create()
        }

        // Remove lenses from here — handled by DoxaCodeLensProvider
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

        private fun tokenTypeToTextAttributes(type: String): TextAttributesKey? = when (type) {
            "keyword" -> DefaultLanguageHighlighterColors.KEYWORD
            "comment" -> DefaultLanguageHighlighterColors.LINE_COMMENT
            "number" -> DefaultLanguageHighlighterColors.NUMBER
            "string" -> DefaultLanguageHighlighterColors.STRING
            "operator" -> DefaultLanguageHighlighterColors.OPERATION_SIGN
            "type" -> DefaultLanguageHighlighterColors.CLASS_REFERENCE
            "function" -> DefaultLanguageHighlighterColors.FUNCTION_CALL
            "variable" -> DefaultLanguageHighlighterColors.LOCAL_VARIABLE
            "parameter" -> DefaultLanguageHighlighterColors.PARAMETER
            "property" -> DefaultLanguageHighlighterColors.INSTANCE_FIELD
            "enumMember" -> DefaultLanguageHighlighterColors.CONSTANT
            "class" -> DefaultLanguageHighlighterColors.CLASS_REFERENCE
            "modifier" -> DefaultLanguageHighlighterColors.METADATA
            "namespace" -> DefaultLanguageHighlighterColors.IDENTIFIER
            else -> null
        }
    }
}
