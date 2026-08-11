package doxa.lang

import com.intellij.openapi.components.PersistentStateComponent
import com.intellij.openapi.components.State
import com.intellij.openapi.components.Storage
import com.intellij.util.xmlb.XmlSerializerUtil

/**
 * Persistent settings for the Doxa plugin.
 *
 * Stores the path to the Doxa language server binary.  Defaults to
 * the bundled AOT binary extracted to the plugin's directory.
 */
@State(
    name = "DoxaSettings",
    storages = [Storage("doxa.xml")]
)
class DoxaSettings : PersistentStateComponent<DoxaSettings> {

    /** Path to the `doxa` binary or command. */
    var binaryPath: String = ""

    override fun getState(): DoxaSettings = this

    override fun loadState(state: DoxaSettings) {
        XmlSerializerUtil.copyBean(state, this)
    }

    companion object {
        val instance: DoxaSettings
            get() = com.intellij.openapi.application.ApplicationManager
                .getApplication().getService(DoxaSettings::class.java)
    }
}
