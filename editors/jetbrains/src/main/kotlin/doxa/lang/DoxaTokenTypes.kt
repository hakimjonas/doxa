package doxa.lang

import com.intellij.psi.tree.IElementType
import org.jetbrains.annotations.NonNls

class DoxaTokenType(debugName: @NonNls String) : IElementType(debugName, DoxaLanguage.INSTANCE)

object DoxaTokenTypes {
    @JvmField val IDENT = DoxaTokenType("IDENT")
    @JvmField val LPAREN = DoxaTokenType("LPAREN")
    @JvmField val RPAREN = DoxaTokenType("RPAREN")
    @JvmField val LBRACE = DoxaTokenType("LBRACE")
    @JvmField val RBRACE = DoxaTokenType("RBRACE")
    @JvmField val LBRACK = DoxaTokenType("LBRACK")
    @JvmField val RBRACK = DoxaTokenType("RBRACK")
}
