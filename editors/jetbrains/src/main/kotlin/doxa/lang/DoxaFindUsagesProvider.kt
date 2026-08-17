package doxa.lang

import com.intellij.lang.findUsages.FindUsagesProvider
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiNamedElement
import javax.swing.Icon

class DoxaFindUsagesProvider : FindUsagesProvider {

    override fun getWordsScanner() = null

    override fun canFindUsagesFor(element: PsiElement): Boolean =
        element is PsiNamedElement && element.language is DoxaLanguage

    override fun getHelpId(element: PsiElement) = null

    override fun getType(element: PsiElement): String = "symbol"

    override fun getDescriptiveName(element: PsiElement): String =
        (element as? PsiNamedElement)?.name ?: "unknown"

    override fun getNodeText(element: PsiElement, useFullName: Boolean): String =
        (element as? PsiNamedElement)?.name ?: element.text
}
