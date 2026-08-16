package doxa.lang

import com.intellij.codeInsight.navigation.actions.GotoDeclarationHandler
import com.intellij.openapi.editor.Editor
import com.intellij.openapi.vfs.VirtualFileManager
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiFile
import com.intellij.psi.PsiManager

class DoxaGotoDeclarationHandler : GotoDeclarationHandler {

    override fun getGotoDeclarationTargets(
        sourceElement: PsiElement?,
        offset: Int,
        editor: Editor?,
    ): Array<PsiElement>? {
        if (sourceElement == null) return null
        val file = sourceElement.containingFile ?: return null
        if (file.language !is DoxaLanguage) return null

        val service = DoxaLspService.getInstance(file.project)
        if (!service.connector.isRunning) return null

        val virtualFile = file.virtualFile ?: return null
        val uri = virtualFile.url
        val document = file.viewProvider.document ?: return null
        try {
            // IntelliJ invokes this extension point on the UI thread. The
            // service returns a cached target or starts a background lookup.
            val response = service.definitionAt(uri, document.text, offset)
            val location = when (response) {
                is Map<*, *> -> response
                is List<*> -> response.firstOrNull() as? Map<*, *>
                else -> null
            } ?: return null
            val targetUri = location["uri"] as? String ?: return null
            val range = location["range"] as? Map<*, *> ?: return null
            val start = range["start"] as? Map<*, *> ?: return null
            val targetLine = (start["line"] as? Number)?.toInt() ?: 0
            val targetChar = (start["character"] as? Number)?.toInt() ?: 0

            val targetFile = VirtualFileManager.getInstance().findFileByUrl(targetUri) ?: return null

            val targetPsiFile = PsiManager.getInstance(file.project).findFile(targetFile) ?: return null
            val targetDocument = targetPsiFile.viewProvider.document ?: return null
            val targetOffset = offsetFor(targetDocument.text, targetLine, targetChar)

            val targetElement = targetPsiFile.findElementAt(targetOffset)
                ?: return arrayOf(targetPsiFile)
            return arrayOf(targetElement)
        } catch (_: Exception) {
            return null
        }
    }

    companion object {
        private fun offsetFor(text: String, line: Int, character: Int): Int {
            var currentLine = 0
            var offset = 0
            while (offset < text.length) {
                if (currentLine == line) return (offset + character).coerceIn(0, text.length)
                if (text[offset] == '\n') currentLine++
                else if (text[offset] == '\r') {
                    if (offset + 1 < text.length && text[offset + 1] == '\n') offset++
                    currentLine++
                }
                offset++
            }
            return text.length
        }
    }
}
