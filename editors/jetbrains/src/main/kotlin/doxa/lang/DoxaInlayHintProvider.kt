package doxa.lang

import com.intellij.codeInsight.hints.*
import com.intellij.openapi.editor.Editor
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiFile
import javax.swing.JComponent
import javax.swing.JLabel

class DoxaInlayHintProvider : InlayHintsProvider<NoSettings> {

    override val key = SettingsKey<NoSettings>("doxa.inlay.hints")
    override val name = "Doxa Types"
    override val previewText = "val x : Nat"
    override val description: String? = null

    override fun createSettings() = NoSettings()

    override fun createConfigurable(settings: NoSettings): ImmediateConfigurable {
        return object : ImmediateConfigurable {
            override fun createComponent(listener: ChangeListener): JComponent =
                JLabel("Type annotations from the Doxa language server")
        }
    }

    override fun getCollectorFor(
        file: PsiFile,
        editor: Editor,
        settings: NoSettings,
        sink: InlayHintsSink,
    ): InlayHintsCollector? {
        if (file.language !is DoxaLanguage) return null

        val connector = DoxaLspService.getInstance(file.project).connector
        if (!connector.isRunning) return null

        val virtualFile = file.virtualFile ?: return null
        val uri = virtualFile.url
        connector.ensureFileSent(uri, editor.document.text)

        // Fetch all hints once.
        val hints = mutableListOf<Pair<Int, String>>() // (offset, label)
        try {
            val response = connector.sendRequestBlocking("textDocument/inlayHint", mapOf(
                "textDocument" to mapOf("uri" to uri),
                "range" to mapOf(
                    "start" to mapOf("line" to 0, "character" to 0),
                    "end" to mapOf("line" to editor.document.lineCount, "character" to 0),
                ),
            ))
            val data = response as? List<*> ?: emptyList<Any>()
            for (h in data) {
                val hint = h as? Map<*, *> ?: continue
                val pos = hint["position"] as? Map<*, *> ?: continue
                val label = hint["label"] as? String ?: continue
                val line = (pos["line"] as? Number)?.toInt() ?: continue
                val char = (pos["character"] as? Number)?.toInt() ?: 0
                val offset = offsetFor(editor.document.text, line, char)
                hints.add(offset to label)
            }
        } catch (_: Exception) {
        }

        val factory = com.intellij.codeInsight.hints.presentation.PresentationFactory(editor)

        return object : InlayHintsCollector {
            override fun collect(element: PsiElement, editor: Editor, sink: InlayHintsSink): Boolean {
                if (element === file) {
                    for ((offset, label) in hints) {
                        sink.addInlineElement(offset, true, factory.smallText(label))
                    }
                }
                return true
            }
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
