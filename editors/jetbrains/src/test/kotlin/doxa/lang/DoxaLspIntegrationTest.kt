package doxa.lang

import com.intellij.testFramework.fixtures.BasePlatformTestCase
import com.intellij.openapi.vfs.LocalFileSystem
import com.intellij.psi.PsiManager
import com.intellij.util.ui.UIUtil
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import java.nio.file.Files
import java.nio.file.Path

class DoxaLspIntegrationTest : BasePlatformTestCase() {
    private lateinit var connector: DoxaLspConnector
    private lateinit var directory: Path

    override fun setUp() {
        super.setUp()
        directory = Files.createTempDirectory("doxa-jetbrains-lsp-")
        DoxaSettings.instance.binaryPath = System.getProperty("doxa.executable")
        connector = DoxaLspConnector(project)
        connector.start()
        waitFor("Doxa language server to initialize") { connector.isRunning }
    }

    override fun tearDown() {
        try {
            connector.stop()
            directory.toFile().deleteRecursively()
        } finally {
            super.tearDown()
        }
    }

    fun testRealServerSuppliesDocumentFeaturesAndDiagnostics() {
        val file = directory.resolve("identity.doxa")
        val source = "fun identity[A: Type](value: A) : A = value\n"
        Files.writeString(file, source)
        val uri = file.toUri().toString()

        connector.didOpen(uri, source)

        val hover = connector.sendRequestBlocking(
            "textDocument/hover",
            positionParams(uri, source, source.indexOf("identity")),
        )
        val definition = connector.sendRequestBlocking(
            "textDocument/definition",
            positionParams(uri, source, source.indexOf("identity")),
        )
        val semanticTokens = connector.sendRequestBlocking(
            "textDocument/semanticTokens/full",
            mapOf("textDocument" to mapOf("uri" to uri)),
        ) as? Map<*, *>
        val formatting = connector.sendRequestBlocking(
            "textDocument/formatting",
            mapOf(
                "textDocument" to mapOf("uri" to uri),
                "options" to mapOf("tabSize" to 2, "insertSpaces" to true),
            ),
        ) as? List<*>

        assertNotNull(hover)
        assertNotNull(definition)
        assertTrue((semanticTokens?.get("data") as? List<*>)?.isNotEmpty() == true)
        assertNotNull(formatting)

        connector.didChange(uri, "val broken : Type = missing\n")
        waitFor("diagnostics after an invalid edit") {
            connector.diagnosticsFor(uri).isNotEmpty()
        }

        connector.didChange(uri, source)
        waitFor("diagnostics to clear after recovery") {
            connector.diagnosticsFor(uri).isEmpty()
        }
        assertFalse(connector.diagnosticsFor(uri).isNotEmpty())
    }

    fun testRestartReplaysOpenDocumentSnapshots() {
        val file = directory.resolve("restart.doxa")
        val source = "fun identity[A: Type](value: A) : A = value\n"
        val changedSource = "fun updated[A: Type](value: A) : A = value\n"
        Files.writeString(file, source)
        val uri = file.toUri().toString()
        connector.didOpen(uri, source)
        connector.didChange(uri, changedSource)
        connector.restart()
        waitFor("restarted Doxa language server to initialize") { connector.isRunning }

        val definition = connector.sendRequestBlocking(
            "textDocument/definition",
            positionParams(uri, changedSource, changedSource.indexOf("updated")),
        )
        assertNotNull(definition)
    }

    fun testRealServerRechecksImportAfterWatchedFileChange() {
        val dependency = directory.resolve("dependency.doxa")
        val root = directory.resolve("root.doxa")
        val dependencySource = "fun identity{A: Type}(value: A) : A = value\n"
        val rootSource = "import \"dependency.doxa\"\nfun use{A: Type}(value: A) : A = identity value\n"
        Files.writeString(dependency, dependencySource)
        Files.writeString(root, rootSource)
        val rootUri = root.toUri().toString()

        connector.didOpen(rootUri, rootSource)
        requestSemanticTokens(rootUri)
        assertTrue(connector.diagnosticsFor(rootUri).isEmpty())

        Files.writeString(dependency, "fun renamed{A: Type}(value: A) : A = value\n")
        connector.sendNotification(
            "workspace/didChangeWatchedFiles",
            mapOf("changes" to listOf(mapOf("uri" to dependency.toUri().toString(), "type" to 2))),
        )
        requestSemanticTokens(rootUri)
        waitFor("imported-file diagnostics") { connector.diagnosticsFor(rootUri).isNotEmpty() }

        Files.writeString(dependency, dependencySource)
        connector.sendNotification(
            "workspace/didChangeWatchedFiles",
            mapOf("changes" to listOf(mapOf("uri" to dependency.toUri().toString(), "type" to 2))),
        )
        requestSemanticTokens(rootUri)
        waitFor("recovered imported-file diagnostics") { connector.diagnosticsFor(rootUri).isEmpty() }
    }

    fun testRealServerResolvesTypeclassesImportsToProjectFiles() {
        val bool = directory.resolve("bool.doxa")
        val nat = directory.resolve("nat.doxa")
        val typeclasses = directory.resolve("typeclasses.doxa")
        Files.writeString(bool, "data Bool : Type { true_ : Bool; false_ : Bool; }\n")
        Files.writeString(nat, "data Nat : Type { zero : Nat; succ : Nat -> Nat; }\n")
        val source = """
            import "bool.doxa"
            import "nat.doxa"
            fun choose(n: Nat) : Bool = match n {
              case zero => false_
              case succ _ => true_
            }
        """.trimIndent()
        Files.writeString(typeclasses, source)
        val uri = typeclasses.toUri().toString()
        connector.didOpen(uri, source)

        val falseLocation = connector.sendRequestBlocking(
            "textDocument/definition",
            positionParams(uri, source, source.indexOf("false_")),
        ) as Map<*, *>
        val zeroLocation = connector.sendRequestBlocking(
            "textDocument/definition",
            positionParams(uri, source, source.indexOf("zero")),
        ) as Map<*, *>

        assertLocationResolves(falseLocation, bool, "false_")
        assertLocationResolves(zeroLocation, nat, "zero")
    }

    fun testGotoDeclarationHandlerNavigatesAcrossImportedFiles() {
        val bool = directory.resolve("bool.doxa")
        val nat = directory.resolve("nat.doxa")
        val typeclasses = directory.resolve("typeclasses.doxa")
        Files.writeString(bool, "data Bool : Type { true_ : Bool; false_ : Bool; }\n")
        Files.writeString(nat, "data Nat : Type { zero : Nat; succ : Nat -> Nat; }\n")
        val source = """
            import "bool.doxa"
            import "nat.doxa"
            fun choose(n: Nat) : Bool = match n {
              case zero => false_
              case succ _ => true_
            }
        """.trimIndent()
        Files.writeString(typeclasses, source)
        val virtualFile = LocalFileSystem.getInstance().refreshAndFindFileByNioFile(typeclasses)!!
        val psiFile = PsiManager.getInstance(project).findFile(virtualFile)!!
        val service = DoxaLspService.getInstance(project)
        service.stopServer()
        service.startServer()
        waitFor("project Doxa language server to initialize") { service.connector.isRunning }
        service.connector.didOpen(virtualFile.url, source)
        service.connector.sendRequestBlocking(
            "textDocument/semanticTokens/full",
            mapOf("textDocument" to mapOf("uri" to virtualFile.url)),
        )
        val directFalseLocation = service.connector.sendRequestBlocking(
            "textDocument/definition",
            positionParams(virtualFile.url, source, source.indexOf("false_")),
        ) as Map<*, *>
        assertEquals(bool.toUri().toString(), directFalseLocation["uri"])
        val handler = DoxaGotoDeclarationHandler()

        assertCachedGotoTarget(handler, psiFile, source.indexOf("false_"), bool)
        assertCachedGotoTarget(handler, psiFile, source.indexOf("zero"), nat)
        assertCachedGotoTarget(handler, psiFile, source.indexOf("bool.doxa") + 1, bool)
        service.stopServer()
    }

    private fun positionParams(uri: String, text: String, offset: Int): Map<String, Any> {
        val (line, character) = DoxaDocumentationProvider.positionAt(text, offset)
        return mapOf(
            "textDocument" to mapOf("uri" to uri),
            "position" to mapOf("line" to line, "character" to character),
        )
    }

    private fun requestSemanticTokens(uri: String) {
        connector.sendRequestBlocking(
            "textDocument/semanticTokens/full",
            mapOf("textDocument" to mapOf("uri" to uri)),
        )
    }

    private fun assertLocationResolves(location: Map<*, *>, file: Path, expectedText: String) {
        val uri = location["uri"] as String
        assertTrue(uri.endsWith(file.fileName.toString()))
        val range = location["range"] as Map<*, *>
        val start = range["start"] as Map<*, *>
        val line = (start["line"] as Number).toInt()
        val character = (start["character"] as Number).toInt()
        val text = Files.readString(file)
        val offset = text.lineSequence().take(line).sumOf { it.length + 1 } + character
        assertTrue(text.startsWith(expectedText, offset))
    }

    private fun assertCachedGotoTarget(
        handler: DoxaGotoDeclarationHandler,
        file: com.intellij.psi.PsiFile,
        offset: Int,
        expectedFile: Path,
    ) {
        val source = file.findElementAt(offset)!!
        // The first uncached call returns immediately and starts the LSP lookup.
        assertTrue(handler.getGotoDeclarationTargets(source, offset, null).isNullOrEmpty())
        waitFor("cached declaration target") {
            handler.getGotoDeclarationTargets(source, offset, null)?.singleOrNull() != null
        }
        val target = handler.getGotoDeclarationTargets(source, offset, null)?.singleOrNull()
        assertNotNull(target)
        assertEquals(expectedFile.fileName.toString(), target!!.containingFile.virtualFile.name)
    }

    private fun waitFor(description: String, condition: () -> Boolean) {
        val deadline = System.nanoTime() + 15_000_000_000L
        while (System.nanoTime() < deadline) {
            UIUtil.dispatchAllInvocationEvents()
            if (condition()) return
            Thread.sleep(50)
        }
        UIUtil.dispatchAllInvocationEvents()
        assertTrue("Timed out waiting for $description", condition())
    }
}
