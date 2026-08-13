package doxa.lang

import com.intellij.ide.structureView.*
import com.intellij.ide.util.treeView.smartTree.*
import com.intellij.lang.PsiStructureViewFactory
import com.intellij.navigation.ItemPresentation
import com.intellij.openapi.editor.Editor
import com.intellij.openapi.fileEditor.OpenFileDescriptor
import com.intellij.psi.PsiFile
import javax.swing.Icon

class DoxaStructureViewFactory : PsiStructureViewFactory {
    override fun getStructureViewBuilder(psiFile: PsiFile): StructureViewBuilder {
        return object : TreeBasedStructureViewBuilder() {
            override fun createStructureViewModel(editor: Editor?) =
                DoxaStructureViewModel(editor, psiFile)
            override fun isRootNodeShown() = false
        }
    }
}

class DoxaStructureViewModel(
    editor: Editor?,
    file: PsiFile,
) : StructureViewModelBase(file, editor, DoxaStructureViewElement(file, null, "")),
    StructureViewModel.ElementInfoProvider {

    override fun getSorters() = arrayOf<Sorter>()
    override fun getFilters() = arrayOf<Filter>()
    override fun isAlwaysShowsPlus(element: StructureViewTreeElement) = false
    override fun isAlwaysLeaf(element: StructureViewTreeElement) = element is DoxaStructureViewElement && (element as DoxaStructureViewElement).isLeaf
}

class DoxaStructureViewElement(
    private val file: PsiFile,
    private val parentRange: com.intellij.openapi.util.TextRange?,
    private val name: String,
) : StructureViewTreeElement {

    val isLeaf: Boolean get() = name.isNotEmpty()

    private val children: List<DoxaStructureViewElement> by lazy {
        if (name.isNotEmpty()) {
            // Named symbols are leaf nodes.
            emptyList()
        } else {
            loadSymbols()
        }
    }

    override fun getValue() = this
    override fun getChildren(): Array<TreeElement> = children.toTypedArray()

    override fun getPresentation(): ItemPresentation = object : ItemPresentation {
        override fun getPresentableText() = name.ifEmpty { file.name }
        override fun getIcon(unused: Boolean) = null
        override fun getLocationString() = null
    }

    override fun navigate(requestFocus: Boolean) {
        val offset = parentRange?.startOffset ?: 0
        OpenFileDescriptor(file.project, file.virtualFile, offset).navigate(requestFocus)
    }

    override fun canNavigate() = true
    override fun canNavigateToSource() = true

    private fun loadSymbols(): List<DoxaStructureViewElement> {
        val connector = DoxaLspService.getInstance(file.project).connector
        if (!connector.isRunning) return emptyList()

        val virtualFile = file.virtualFile ?: return emptyList()
        val uri = virtualFile.url
        val document = file.viewProvider.document ?: return emptyList()
        connector.ensureFileSent(uri, document.text)

        return try {
            val symbols = connector.featuresFor(uri)?.symbols ?: return emptyList()
            symbols.mapNotNull { s ->
                val sym = s as? Map<*, *> ?: return@mapNotNull null
                val name = sym["name"] as? String ?: return@mapNotNull null
                val detail = sym["detail"] as? String ?: ""
                val range = sym["range"] as? Map<*, *>
                val start = range?.get("start") as? Map<*, *>
                val line = (start?.get("line") as? Number)?.toInt() ?: 0
                val char = (start?.get("character") as? Number)?.toInt() ?: 0
                val offset = offsetFor(document.text, line, char)
                DoxaStructureViewElement(file, com.intellij.openapi.util.TextRange(offset, offset + name.length), "$name $detail")
            }
        } catch (_: Exception) {
            emptyList()
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
