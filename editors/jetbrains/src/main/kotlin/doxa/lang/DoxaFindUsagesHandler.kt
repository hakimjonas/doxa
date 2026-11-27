package doxa.lang

import com.intellij.find.findUsages.FindUsagesHandler
import com.intellij.find.findUsages.FindUsagesOptions
import com.intellij.openapi.actionSystem.DataContext
import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.vfs.VirtualFileManager
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiFile
import com.intellij.psi.PsiManager
import com.intellij.usageView.UsageInfo
import com.intellij.util.Processor

/**
 * Find Usages backed by the language server's `textDocument/references`.
 *
 * The plugin parses Doxa only for PSI-shaped identifiers; the authoritative
 * reference set comes from the server. The handler translates each returned
 * location into a [UsageInfo] for the IDE's Usage View.
 */
class DoxaFindUsagesHandler(element: PsiElement) : FindUsagesHandler(element) {
    override fun getFindUsagesOptions(context: DataContext?): FindUsagesOptions =
        super.getFindUsagesOptions(context).also { it.isSearchForTextOccurrences = false }

    override fun processElementUsages(
        element: PsiElement,
        processor: Processor<in UsageInfo>,
        options: FindUsagesOptions,
    ): Boolean {
        val file = element.containingFile as? PsiFile ?: return true
        val virtualFile = file.virtualFile ?: return true
        val document = file.viewProvider.document ?: return true
        val service = DoxaLspService.getInstance(element.project)
        if (!service.connector.isRunning) return true
        val references = service.referencesAt(
            virtualFile.url,
            document.text,
            element.textOffset,
            includeDeclaration = true,
        )
        for (reference in references) {
            ProgressManager.checkCanceled()
            val location = reference as? Map<*, *> ?: continue
            val uri = location["uri"] as? String ?: continue
            val range = location["range"] as? Map<*, *> ?: continue
            val start = range["start"] as? Map<*, *> ?: continue
            val end = range["end"] as? Map<*, *> ?: continue
            val startLine = (start["line"] as? Number)?.toInt() ?: continue
            val startCharacter = (start["character"] as? Number)?.toInt() ?: continue
            val endLine = (end["line"] as? Number)?.toInt() ?: continue
            val endCharacter = (end["character"] as? Number)?.toInt() ?: continue
            val referencedFile =
                VirtualFileManager.getInstance().findFileByUrl(uri) ?: continue
            val psiFile =
                PsiManager.getInstance(element.project).findFile(referencedFile) ?: continue
            val text = psiFile.text
            val startOffset = offsetAt(text, startLine, startCharacter)
            val endOffset = offsetAt(text, endLine, endCharacter)
            if (!processor.process(UsageInfo(psiFile, startOffset, endOffset))) return false
        }
        return true
    }

    private fun offsetAt(text: String, line: Int, character: Int): Int {
        var offset = 0
        var currentLine = 0
        while (currentLine < line && offset < text.length) {
            if (text[offset] == '\n') currentLine++
            offset++
        }
        return (offset + character).coerceAtMost(text.length)
    }
}
