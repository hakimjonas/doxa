package doxa.lang

import com.intellij.lang.BracePair
import com.intellij.lang.PairedBraceMatcher
import com.intellij.psi.PsiFile
import com.intellij.psi.tree.IElementType

class DoxaBraceMatcher : PairedBraceMatcher {
    override fun getPairs() = arrayOf(
        BracePair(DoxaTokenTypes.LPAREN, DoxaTokenTypes.RPAREN, false),
        BracePair(DoxaTokenTypes.LBRACE, DoxaTokenTypes.RBRACE, false),
        BracePair(DoxaTokenTypes.LBRACK, DoxaTokenTypes.RBRACK, false),
    )

    override fun isPairedBracesAllowedBeforeType(lbraceType: IElementType, contextType: IElementType?) = true
    override fun getCodeConstructStart(file: PsiFile?, openingBraceOffset: Int) = openingBraceOffset
}
