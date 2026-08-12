package doxa.lang

import com.intellij.lang.ASTNode
import com.intellij.lang.folding.FoldingBuilder
import com.intellij.lang.folding.FoldingDescriptor
import com.intellij.openapi.editor.Document
import com.intellij.psi.PsiElement

class DoxaFoldingBuilder : FoldingBuilder {

    override fun buildFoldRegions(node: ASTNode, document: Document): Array<FoldingDescriptor> {
        val psiFile = node.psi.containingFile ?: return emptyArray()
        val connector = DoxaLspService.getInstance(psiFile.project).connector
        if (!connector.isRunning) return emptyArray()

        val virtualFile = psiFile.virtualFile ?: return emptyArray()
        val uri = virtualFile.url
        connector.ensureFileSent(uri, document.text)

        val params = mapOf("textDocument" to mapOf("uri" to uri))
        try {
            val response = connector.sendRequestBlocking("textDocument/foldingRange", params)
            val ranges = response as? List<*> ?: return emptyArray()
            return ranges.mapNotNull { r ->
                val range = r as? Map<*, *> ?: return@mapNotNull null
                val startLine = (range["startLine"] as? Number)?.toInt() ?: return@mapNotNull null
                val endLine = (range["endLine"] as? Number)?.toInt() ?: return@mapNotNull null
                val startOffset = document.getLineStartOffset(startLine)
                val endOffset = document.getLineEndOffset(endLine)
                FoldingDescriptor(node, com.intellij.openapi.util.TextRange(startOffset, endOffset))
            }.toTypedArray()
        } catch (_: Exception) {
            return emptyArray()
        }
    }

    override fun getPlaceholderText(node: ASTNode): String = "{...}"

    override fun isCollapsedByDefault(node: ASTNode): Boolean = false
}
