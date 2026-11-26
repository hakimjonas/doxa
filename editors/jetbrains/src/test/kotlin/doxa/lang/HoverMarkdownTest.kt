package doxa.lang

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HoverMarkdownTest {
    @Test
    fun rendersFencedBlockAndProse() {
        val html = renderHoverMarkdown("```doxa\ndata\n```\n\nDeclares an inductive type.")
        assertEquals(
            "<pre><code>data</code></pre><p>Declares an inductive type.</p>",
            html,
        )
    }

    @Test
    fun rendersSignatureOnly() {
        val html = renderHoverMarkdown("```doxa\nNat : Type\n```")
        assertEquals("<pre><code>Nat : Type</code></pre>", html)
    }

    @Test
    fun rendersInlineCode() {
        val html = renderHoverMarkdown("Use `plus` for addition.")
        assertEquals("<p>Use <code>plus</code> for addition.</p>", html)
    }

    @Test
    fun escapesHtml() {
        val html = renderHoverMarkdown("```doxa\nEq A < B\n```")
        assertTrue(html.contains("Eq A &lt; B"))
        assertFalse(html.contains("< B"))
    }

    @Test
    fun rendersTwoParagraphs() {
        val html = renderHoverMarkdown("One.\n\nTwo.")
        assertEquals("<p>One.</p><p>Two.</p>", html)
    }

    @Test
    fun rendersUnclosedFence() {
        val html = renderHoverMarkdown("```doxa\ndata")
        assertEquals("<pre><code>data</code></pre>", html)
    }
}
