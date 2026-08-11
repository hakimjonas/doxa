package doxa.lang

import com.intellij.extapi.psi.PsiFileBase
import com.intellij.lang.ASTNode
import com.intellij.lang.ParserDefinition
import com.intellij.lang.PsiParser
import com.intellij.lexer.Lexer
import com.intellij.openapi.project.Project
import com.intellij.psi.FileViewProvider
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiFile
import com.intellij.psi.tree.IFileElementType
import com.intellij.psi.tree.IElementType
import com.intellij.psi.tree.TokenSet

class DoxaFile(viewProvider: FileViewProvider) : PsiFileBase(viewProvider, DoxaLanguage.INSTANCE) {
    override fun getFileType() = DoxaFileType()
}

class DoxaParserDefinition : ParserDefinition {
    override fun createLexer(project: Project?): Lexer = DoxaLexer()

    override fun createParser(project: Project?): PsiParser =
        object : PsiParser {
            override fun parse(root: IElementType, builder: com.intellij.lang.PsiBuilder): ASTNode {
                val marker = builder.mark()
                while (!builder.eof()) builder.advanceLexer()
                marker.done(root)
                return builder.treeBuilt
            }
        }

    override fun getFileNodeType(): IFileElementType =
        IFileElementType("DOXA_FILE", DoxaLanguage.INSTANCE)

    override fun getWhitespaceTokens(): TokenSet = TokenSet.EMPTY
    override fun getCommentTokens(): TokenSet = TokenSet.EMPTY
    override fun getStringLiteralElements(): TokenSet = TokenSet.EMPTY

    override fun createFile(viewProvider: FileViewProvider): PsiFile =
        DoxaFile(viewProvider)

    override fun spaceExistenceTypeBetweenTokens(
        left: ASTNode?, right: ASTNode?,
    ): ParserDefinition.SpaceRequirements = ParserDefinition.SpaceRequirements.MAY

    override fun createElement(node: ASTNode?): PsiElement =
        com.intellij.psi.impl.source.tree.LeafPsiElement(DoxaTokenTypes.IDENT, "")
}

class DoxaLexer : Lexer() {
    private var buffer: CharSequence = ""
    private var startOffset: Int = 0
    private var endOffset: Int = 0

    override fun start(buffer: CharSequence, startOffset: Int, endOffset: Int, initialState: Int) {
        this.buffer = buffer
        this.startOffset = startOffset
        this.endOffset = endOffset
    }

    override fun advance() {
        startOffset = endOffset
        if (endOffset >= buffer.length || startOffset > 0) return
        endOffset = buffer.length
    }

    override fun getState(): Int = 0
    override fun getTokenType(): IElementType? =
        if (endOffset > startOffset) DoxaTokenTypes.IDENT else null
    override fun getTokenStart(): Int = startOffset
    override fun getTokenEnd(): Int = endOffset
    override fun getBufferSequence(): CharSequence = buffer
    override fun getBufferEnd(): Int = buffer.length

    override fun getCurrentPosition(): com.intellij.lexer.LexerPosition =
        object : com.intellij.lexer.LexerPosition {
            override fun getOffset(): Int = startOffset
            override fun getState(): Int = 0
        }

    override fun restore(position: com.intellij.lexer.LexerPosition) {
        startOffset = position.offset
        endOffset = position.offset
    }
}
