package doxa.lang

import com.intellij.lang.findUsages.FindUsagesProvider
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiNamedElement
import javax.swing.Icon

class DoxaFindUsagesProvider : FindUsagesProvider {

    override fun getWordsScanner() = null

    override fun canFindUsagesFor(element: PsiElement): Boolean =
        isDoxaIdentifier(element)

    override fun getHelpId(element: PsiElement) = null

    override fun getType(element: PsiElement): String = "symbol"

    override fun getDescriptiveName(element: PsiElement): String =
        (element as? PsiNamedElement)?.name ?: element.text

    override fun getNodeText(element: PsiElement, useFullName: Boolean): String =
        (element as? PsiNamedElement)?.name ?: element.text
}

/**
 * Whether [element] is a Doxa identifier leaf.
 *
 * The plugin has no named PSI elements; Find Usages targets the identifier
 * leaf and delegates the actual search to the language server.
 */
internal fun isDoxaIdentifier(element: PsiElement): Boolean =
    element.language is DoxaLanguage &&
        element.node?.elementType == DoxaTokenTypes.IDENT
