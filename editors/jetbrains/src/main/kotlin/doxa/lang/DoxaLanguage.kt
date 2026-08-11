package doxa.lang

import com.intellij.lang.Language
import com.intellij.openapi.fileTypes.LanguageFileType
import com.intellij.openapi.util.IconLoader
import javax.swing.Icon

class DoxaLanguage private constructor() : Language("Doxa") {
    companion object {
        val INSTANCE = DoxaLanguage()
    }
}

/** File type for `.doxa` files, registered in plugin.xml. */
class DoxaFileType : LanguageFileType(DoxaLanguage.INSTANCE) {

    override fun getName(): String = "Doxa"

    override fun getDescription(): String = "Doxa proof checker"

    override fun getDefaultExtension(): String = "doxa"

    override fun getIcon(): Icon = DoxaIcons.FILE
}

/** Icon loader — reads `icons/doxa-file.svg` from the plugin classpath. */
object DoxaIcons {
    val FILE: Icon by lazy {
        IconLoader.getIcon("icons/doxa-file.svg", DoxaIcons::class.java)
    }
}
