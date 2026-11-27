package doxa.lang

/**
 * Renders the Markdown subset used by the Doxa LSP hover responses as the
 * HTML that the platform documentation popup expects.
 *
 * The server sends fenced code blocks (normally `doxa`) followed by optional
 * prose paragraphs. The documentation popup does not render Markdown itself,
 * so fenced blocks become `<pre><code>` and prose becomes `<p>` with inline
 * code spans.
 */
internal fun renderHoverMarkdown(markdown: String): String {
    val html = StringBuilder()
    val code = StringBuilder()
    val prose = StringBuilder()
    var inCode = false

    fun flushProse() {
        val text = prose.toString().trim()
        prose.clear()
        if (text.isEmpty()) return
        for (paragraph in text.split(Regex("\\n\\s*\\n"))) {
            val trimmed = paragraph.trim()
            if (trimmed.isEmpty()) continue
            html.append("<p>").append(renderInline(trimmed)).append("</p>")
        }
    }

    for (line in markdown.lines()) {
        val trimmedStart = line.trimStart()
        if (!inCode && trimmedStart.startsWith("```")) {
            flushProse()
            inCode = true
            code.clear()
        } else if (inCode && trimmedStart.startsWith("```")) {
            html
                .append("<pre><code>")
                .append(escapeHtml(code.toString().trimEnd()))
                .append("</code></pre>")
            inCode = false
        } else if (inCode) {
            code.appendLine(line)
        } else {
            prose.appendLine(line)
        }
    }
    if (inCode) {
        // An unclosed fence still renders its contents rather than dropping them.
        html
            .append("<pre><code>")
            .append(escapeHtml(code.toString().trimEnd()))
            .append("</code></pre>")
    } else {
        flushProse()
    }
    return html.toString()
}

private fun renderInline(text: String): String {
    val escaped = escapeHtml(text)
    return escaped.replace(Regex("`([^`]+)`")) { match ->
        "<code>${match.groupValues[1]}</code>"
    }
}

private fun escapeHtml(value: String): String =
    value
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
