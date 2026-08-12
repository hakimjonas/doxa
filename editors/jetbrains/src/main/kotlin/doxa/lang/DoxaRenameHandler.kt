package doxa.lang

import com.intellij.openapi.actionSystem.DataContext
import com.intellij.openapi.editor.Editor
import com.intellij.openapi.project.Project
import com.intellij.openapi.command.WriteCommandAction
import com.intellij.openapi.vfs.VirtualFileManager
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiFile
import com.intellij.refactoring.rename.RenameHandler

class DoxaRenameHandler : RenameHandler {

    override fun isAvailableOnDataContext(dataContext: DataContext): Boolean {
        val file = dataContext.getData(com.intellij.openapi.actionSystem.PlatformCoreDataKeys.PSI_FILE) ?: return false
        return file.language is DoxaLanguage
    }

    override fun isRenaming(dataContext: DataContext): Boolean =
        isAvailableOnDataContext(dataContext)

    override fun invoke(project: Project, elements: Array<out PsiElement>, dataContext: DataContext) {
        val editor = dataContext.getData(com.intellij.openapi.actionSystem.PlatformCoreDataKeys.EDITOR) ?: return
        val file = dataContext.getData(com.intellij.openapi.actionSystem.PlatformCoreDataKeys.PSI_FILE) ?: return
        rename(project, editor, file)
    }

    override fun invoke(project: Project, editor: Editor, file: PsiFile, dataContext: DataContext) {
        rename(project, editor, file)
    }

    private fun rename(project: Project, editor: Editor, file: PsiFile) {
        val connector = DoxaLspService.getInstance(project).connector
        if (!connector.isRunning) return

        val virtualFile = file.virtualFile ?: return
        val uri = virtualFile.url
        val offset = editor.caretModel.offset
        val text = editor.document.text
        val position = offsetToPosition(text, offset)

        val word = getWordAtCursor(editor)
        if (word.isEmpty()) return

        // Ask the user for the new name.
        val newName = com.intellij.openapi.ui.Messages.showInputDialog(
            project,
            "Rename '$word' to:",
            "Rename",
            null,
            word,
            null,
        ) ?: return

        if (newName.isEmpty() || newName == word) return

        // Execute the rename.
        val params = mapOf(
            "textDocument" to mapOf("uri" to uri),
            "position" to mapOf("line" to position.first, "character" to position.second),
            "newName" to newName,
        )

        try {
            val response = connector.sendRequestBlocking("textDocument/rename", params) as? Map<*, *> ?: return
            val changes = response["changes"] as? Map<*, *> ?: return
            for ((changeUri, edits) in changes) {
                val editList = edits as? List<*> ?: continue
                val targetUri = changeUri as? String ?: continue
                val targetFile = VirtualFileManager.getInstance().findFileByUrl(targetUri) ?: continue
                val targetDoc = com.intellij.openapi.fileEditor.FileDocumentManager.getInstance().getDocument(targetFile) ?: continue

                val parsedEdits = editList.mapNotNull { edit ->
                    val e = edit as? Map<*, *> ?: return@mapNotNull null
                    val range = e["range"] as? Map<*, *> ?: return@mapNotNull null
                    val start = range["start"] as? Map<*, *> ?: return@mapNotNull null
                    val end = range["end"] as? Map<*, *> ?: return@mapNotNull null
                    val sl = (start["line"] as? Number)?.toInt() ?: 0
                    val sc = (start["character"] as? Number)?.toInt() ?: 0
                    val el = (end["line"] as? Number)?.toInt() ?: 0
                    val ec = (end["character"] as? Number)?.toInt() ?: 0
                    val newText = e["newText"] as? String ?: return@mapNotNull null
                    val startOffset = offsetFor(targetDoc.text, sl, sc)
                    val endOffset = offsetFor(targetDoc.text, el, ec)
                    Triple(startOffset, endOffset, newText)
                }.sortedByDescending { it.first }

                WriteCommandAction.runWriteCommandAction(project, "Rename '$word'", null, Runnable {
                    for ((startOffset, endOffset, newText) in parsedEdits) {
                        targetDoc.replaceString(startOffset, endOffset, newText)
                    }
                })
            }
        } catch (_: Exception) {
        }
    }

    companion object {
        private fun offsetToPosition(text: String, offset: Int): Pair<Int, Int> {
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

        private fun getWordAtCursor(editor: Editor): String {
            val text = editor.document.text
            val offset = editor.caretModel.offset
            if (offset <= 0 || offset >= text.length) return ""
            var start = offset
            while (start > 0 && (text[start - 1].isLetterOrDigit() || text[start - 1] == '_')) start--
            var end = offset
            while (end < text.length && (text[end].isLetterOrDigit() || text[end] == '_')) end++
            return text.substring(start, end)
        }

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
