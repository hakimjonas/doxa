package doxa.lang

import com.intellij.openapi.components.Service
import com.intellij.openapi.project.Project

@Service(Service.Level.PROJECT)
class DoxaLspService(val project: Project) {
    val connector = DoxaLspConnector(project)

    fun startServer() {
        connector.start()
    }

    fun stopServer() {
        connector.stop()
    }

    companion object {
        fun getInstance(project: Project): DoxaLspService =
            project.getService(DoxaLspService::class.java)
    }
}
