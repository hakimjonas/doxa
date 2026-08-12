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

    override fun getWhitespaceTokens(): TokenSet = TokenSet.create(DoxaTokenTypes.WHITESPACE)
    override fun getCommentTokens(): TokenSet = TokenSet.create(DoxaTokenTypes.LINE_COMMENT, DoxaTokenTypes.BLOCK_COMMENT)
    override fun getStringLiteralElements(): TokenSet = TokenSet.create(DoxaTokenTypes.STRING)

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
        this.endOffset = startOffset
        advance()
    }

    override fun advance() {
        startOffset = endOffset
        if (startOffset >= buffer.length) return

        val ch = buffer[startOffset]
        endOffset = when {
            ch.isWhitespace() -> consumeWhile(startOffset) { it.isWhitespace() }
            ch == '/' && startOffset + 1 < buffer.length && buffer[startOffset + 1] == '/' ->
                consumeUntil(startOffset + 2) { it == '\n' || it == '\r' }
            ch == '/' && startOffset + 1 < buffer.length && buffer[startOffset + 1] == '*' -> {
                val close = buffer.indexOf("*/", startOffset + 2)
                if (close < 0) buffer.length else close + 2
            }
            ch == '"' -> consumeString(startOffset)
            ch.isLetterOrDigit() || ch == '_' -> consumeWhile(startOffset) { it.isLetterOrDigit() || it == '_' }
            else -> startOffset + 1
        }
    }

    override fun getState(): Int = 0
    override fun getTokenType(): IElementType? =
        if (endOffset <= startOffset) null else when {
            buffer[startOffset].isWhitespace() -> DoxaTokenTypes.WHITESPACE
            buffer.startsWith("//", startOffset) -> DoxaTokenTypes.LINE_COMMENT
            buffer.startsWith("/*", startOffset) -> DoxaTokenTypes.BLOCK_COMMENT
            buffer[startOffset] == '"' -> DoxaTokenTypes.STRING
            else -> when (buffer[startOffset]) {
                '(' -> DoxaTokenTypes.LPAREN
                ')' -> DoxaTokenTypes.RPAREN
                '{' -> DoxaTokenTypes.LBRACE
                '}' -> DoxaTokenTypes.RBRACE
                '[' -> DoxaTokenTypes.LBRACK
                ']' -> DoxaTokenTypes.RBRACK
                else -> DoxaTokenTypes.IDENT
            }
        }
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

    private fun consumeWhile(offset: Int, predicate: (Char) -> Boolean): Int {
        var index = offset
        while (index < buffer.length && predicate(buffer[index])) index++
        return index
    }

    private fun consumeUntil(offset: Int, predicate: (Char) -> Boolean): Int {
        var index = offset
        while (index < buffer.length && !predicate(buffer[index])) index++
        return index
    }

    private fun consumeString(offset: Int): Int {
        var index = offset + 1
        while (index < buffer.length) {
            if (buffer[index] == '"' && buffer[index - 1] != '\\') return index + 1
            index++
        }
        return buffer.length
    }
}
