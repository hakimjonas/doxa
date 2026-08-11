package doxa.lang

import com.intellij.codeInsight.daemon.impl.HighlightInfo
import com.intellij.codeInsight.daemon.impl.HighlightVisitor
import com.intellij.codeInsight.daemon.impl.analysis.HighlightInfoHolder
import com.intellij.openapi.editor.DefaultLanguageHighlighterColors
import com.intellij.openapi.editor.colors.TextAttributesKey
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiFile

class DoxaHighlightVisitor : HighlightVisitor {

    private lateinit var holder: HighlightInfoHolder

    companion object {
        private val KEYWORD_SET = setOf(
            "val", "fun", "data", "type", "match", "case", "returning",
            "import", "and", "by", "opaque", "rec", "struct", "where",
            "as", "typeclass", "impl", "theorem", "with", "ind",
        )

        private fun highlightKeyword(text: String, startOffset: Int, endOffset: Int) =
            text in KEYWORD_SET && (endOffset == text.length || !text[endOffset].isLetterOrDigit())

        fun TextAttributesKey.asArray() = arrayOf(this)
    }

    override fun suitableForFile(file: PsiFile): Boolean =
        file.language is DoxaLanguage

    override fun visit(element: PsiElement) {
        if (element.language !is DoxaLanguage) return
        val file = element.containingFile ?: return
        val text = file.text
        if (text.isEmpty()) return

        // Apply instant keyword + comment + number highlighting
        // while the LSP semantic tokens load in the background.
        var offset = 0
        while (offset < text.length) {
            if (offset > 0 && text[offset - 1].isLetterOrDigit()) {
                offset++
                continue
            }

            val remaining = text.substring(offset)
            when {
                remaining.startsWith("//") -> {
                    val end = text.indexOf('\n', offset).let { if (it == -1) text.length else it }
                    holder.add(
                        HighlightInfo.newHighlightInfo(com.intellij.codeInsight.daemon.impl.HighlightInfoType.INFORMATION)
                            .range(offset, end)
                            .textAttributes(DefaultLanguageHighlighterColors.LINE_COMMENT)
                            .create()
                    )
                    offset = end
                }
                remaining.startsWith("/*") -> {
                    val end = text.indexOf("*/", offset + 2)
                    if (end != -1) {
                        holder.add(
                            HighlightInfo.newHighlightInfo(com.intellij.codeInsight.daemon.impl.HighlightInfoType.INFORMATION)
                                .range(offset, end + 2)
                                .textAttributes(DefaultLanguageHighlighterColors.BLOCK_COMMENT)
                                .create()
                        )
                        offset = end + 2
                    } else offset++
                }
                remaining.first().isLetter() -> {
                    val wordEnd = findWordEnd(text, offset + 1)
                    val word = text.substring(offset, wordEnd)
                    if (word in KEYWORD_SET) {
                        holder.add(
                            HighlightInfo.newHighlightInfo(com.intellij.codeInsight.daemon.impl.HighlightInfoType.INFORMATION)
                                .range(offset, wordEnd)
                                .textAttributes(DefaultLanguageHighlighterColors.KEYWORD)
                                .create()
                        )
                    }
                    offset = wordEnd
                }
                remaining.first().isDigit() -> {
                    val numEnd = findNumberEnd(text, offset)
                    holder.add(
                        HighlightInfo.newHighlightInfo(com.intellij.codeInsight.daemon.impl.HighlightInfoType.INFORMATION)
                            .range(offset, numEnd)
                            .textAttributes(DefaultLanguageHighlighterColors.NUMBER)
                            .create()
                    )
                    offset = numEnd
                }
                else -> offset++
            }
        }
    }

    override fun analyze(file: PsiFile, updateWholeFile: Boolean, holder: HighlightInfoHolder, action: Runnable): Boolean {
        if (file.language !is DoxaLanguage) return false
        this.holder = holder
        action.run()
        return true
    }

    override fun clone(): HighlightVisitor = DoxaHighlightVisitor()

    private fun findWordEnd(text: String, start: Int): Int {
        var i = start
        while (i < text.length && (text[i].isLetterOrDigit() || text[i] == '_')) i++
        return i
    }

    private fun findNumberEnd(text: String, start: Int): Int {
        var i = start
        while (i < text.length && text[i].isDigit()) i++
        return i
    }
}
