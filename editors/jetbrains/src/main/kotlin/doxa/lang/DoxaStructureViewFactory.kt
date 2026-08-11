package doxa.lang

import com.intellij.ide.structureView.*
import com.intellij.ide.util.treeView.smartTree.*
import com.intellij.lang.PsiStructureViewFactory
import com.intellij.navigation.ItemPresentation
import com.intellij.openapi.editor.Editor
import com.intellij.openapi.fileEditor.FileEditor
import com.intellij.openapi.project.Project
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
) : StructureViewModelBase(file, editor, DoxaStructureViewElement(file)),
    StructureViewModel.ElementInfoProvider {

    override fun getSorters() = arrayOf<Sorter>()
    override fun getFilters() = arrayOf<Filter>()

    override fun isAlwaysShowsPlus(element: StructureViewTreeElement) = false
    override fun isAlwaysLeaf(element: StructureViewTreeElement) = false
}

class DoxaStructureViewElement(private val file: PsiFile) : StructureViewTreeElement {
    private val children: List<DoxaSymbolElement> by lazy { loadSymbols() }

    override fun getValue() = file
    override fun getChildren(): Array<TreeElement> = children.toTypedArray()

    override fun getPresentation(): ItemPresentation = object : ItemPresentation {
        override fun getPresentableText() = file.name
        override fun getIcon(unused: Boolean) = null
        override fun getLocationString() = null
    }

    override fun navigate(requestFocus: Boolean) {}
    override fun canNavigate() = false
    override fun canNavigateToSource() = false

    private fun loadSymbols(): List<DoxaSymbolElement> {
        val connector = DoxaLspService.getInstance(file.project).connector
        if (!connector.isRunning) return emptyList()

        val virtualFile = file.virtualFile ?: return emptyList()
        val uri = virtualFile.url

        val params = mapOf("textDocument" to mapOf("uri" to uri))
        return try {
            val response = connector.sendRequestBlocking("textDocument/documentSymbol", params)
            val symbols = response as? List<*> ?: return emptyList()
            symbols.mapNotNull { s ->
                val sym = s as? Map<*, *> ?: return@mapNotNull null
                val name = sym["name"] as? String ?: return@mapNotNull null
                val detail = sym["detail"] as? String ?: ""
                DoxaSymbolElement(name, detail)
            }
        } catch (_: Exception) {
            emptyList()
        }
    }
}

class DoxaSymbolElement(
    private val name: String,
    private val detail: String,
) : StructureViewTreeElement {
    override fun getValue() = this
    override fun getChildren(): Array<TreeElement> = emptyArray()

    override fun getPresentation(): ItemPresentation = object : ItemPresentation {
        override fun getPresentableText() = name
        override fun getLocationString() = detail
        override fun getIcon(unused: Boolean) = null
    }

    override fun navigate(requestFocus: Boolean) {}
    override fun canNavigate() = false
    override fun canNavigateToSource() = false
}
