package doxa.lang

import com.intellij.testFramework.fixtures.BasePlatformTestCase

class DoxaParserDefinitionTest : BasePlatformTestCase() {
    fun testPsiContainsLeafAtDeclarationOffset() {
        val file = myFixture.configureByText("sample.doxa", "// comment\nval answer : Type = Type\n")
        val offset = file.text.indexOf("answer")

        val element = file.findElementAt(offset)

        assertNotNull(element)
        assertEquals(offset, element!!.textOffset)
        assertEquals("answer", element.text)
    }
}
