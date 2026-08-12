package doxa.lang

import com.intellij.codeInsight.navigation.actions.GotoDeclarationHandler
import com.intellij.openapi.editor.Editor
import com.intellij.openapi.fileEditor.OpenFileDescriptor
import com.intellij.openapi.vfs.LocalFileSystem
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiFile
import com.intellij.psi.PsiManager
import java.io.File

class DoxaGotoDeclarationHandler : GotoDeclarationHandler {

    private val LOG = com.intellij.openapi.diagnostic.Logger.getInstance(DoxaGotoDeclarationHandler::class.java)

    override fun getGotoDeclarationTargets(
        sourceElement: PsiElement?,
        offset: Int,
        editor: Editor?,
    ): Array<PsiElement>? {
        LOG.info("getGotoDeclarationTargets: source=$sourceElement, lang=${sourceElement?.language}")
        if (sourceElement == null) { LOG.info("  null source"); return null }
        val file = sourceElement.containingFile ?: run { LOG.info("  no containingFile"); return null }
        if (file.language !is DoxaLanguage) { LOG.info("  wrong lang: ${file.language}"); return null }

        val connector = DoxaLspService.getInstance(file.project).connector
        if (!connector.isRunning) { LOG.info("  connector not running"); return null }

        val virtualFile = file.virtualFile ?: run { LOG.info("  no virtualFile"); return null }
        val uri = virtualFile.url
        val document = file.viewProvider.document ?: run { LOG.info("  no document"); return null }
        connector.ensureFileSent(uri, document.text)
        // Let server process didOpen before querying.
        Thread.sleep(500)
        LOG.info("  ensureFileSent, sending definition request")
        val position = DoxaDocumentationProvider.positionAt(document.text, offset)

        val params = mapOf(
            "textDocument" to mapOf("uri" to uri),
            "position" to mapOf("line" to position.first, "character" to position.second),
        )

        try {
            val response = connector.sendRequestBlocking("textDocument/definition", params)
            val locations = response as? List<*> ?: return null
            if (locations.isEmpty()) return null
            val location = locations[0] as? Map<*, *> ?: return null
            val targetUri = location["uri"] as? String ?: return null
            val range = location["range"] as? Map<*, *> ?: return null
            val start = range["start"] as? Map<*, *> ?: return null
            val targetLine = (start["line"] as? Number)?.toInt() ?: 0
            val targetChar = (start["character"] as? Number)?.toInt() ?: 0

            val path = if (targetUri.startsWith("file://")) {
                targetUri.removePrefix("file://")
            } else targetUri
            val targetFile = LocalFileSystem.getInstance().findFileByPath(path)
                ?: LocalFileSystem.getInstance().findFileByIoFile(File(path))
                ?: return null

            val targetPsiFile = PsiManager.getInstance(file.project).findFile(targetFile) ?: return null
            val targetDocument = targetPsiFile.viewProvider.document ?: return null
            val targetOffset = offsetFor(targetDocument.text, targetLine, targetChar)

            val targetElement = targetPsiFile.findElementAt(targetOffset) ?: targetPsiFile
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
