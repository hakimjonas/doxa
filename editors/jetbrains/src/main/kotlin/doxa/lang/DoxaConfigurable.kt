package doxa.lang

import com.intellij.openapi.options.Configurable
import com.intellij.openapi.ui.DialogPanel
import com.intellij.ui.dsl.builder.bindText
import com.intellij.ui.dsl.builder.panel
import javax.swing.JComponent

/**
 * Settings page: `Settings → Languages & Frameworks → Doxa`.
 *
 * Lets the user configure the path to the `doxa` language server binary.
 * The default is `doxa` (on PATH).  Use the bundled AOT binary for
 * zero-dependency operation.
 */
class DoxaConfigurable : Configurable {

    private var binaryPath: String = DoxaSettings.instance.binaryPath.ifEmpty { "doxa" }
    private var panel: DialogPanel? = null

    override fun getDisplayName(): String = "Doxa"

    override fun createComponent(): JComponent {
        panel = panel {
            group("Language Server") {
                row("Binary path:") {
                    textField()
                        .bindText(::binaryPath)
                        .comment(
                            "Command or full path to the Doxa language server binary.\n" +
                            "Default: doxa (requires it on PATH).\n" +
                            "Example: /home/user/.pub-cache/bin/doxa"
                        )
                }
            }
        }
        return panel!!
    }

    override fun isModified(): Boolean =
        binaryPath != (DoxaSettings.instance.binaryPath.ifEmpty { "doxa" })

    override fun apply() {
        DoxaSettings.instance.binaryPath = binaryPath
    }

    override fun reset() {
        binaryPath = DoxaSettings.instance.binaryPath.ifEmpty { "doxa" }
    }
}
