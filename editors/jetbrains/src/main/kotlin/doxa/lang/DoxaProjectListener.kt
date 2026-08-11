package doxa.lang

import com.intellij.openapi.project.Project
import com.intellij.openapi.project.ProjectManagerListener

class DoxaProjectListener : ProjectManagerListener {
    private val LOG = com.intellij.openapi.diagnostic.Logger.getInstance(DoxaProjectListener::class.java)

    @Suppress("DEPRECATION")
    override fun projectOpened(project: Project) {
        LOG.info("Project opened, starting Doxa LSP server")
        DoxaLspService.getInstance(project).startServer()
    }

    override fun projectClosing(project: Project) {
        LOG.info("Project closing, stopping Doxa LSP server")
        DoxaLspService.getInstance(project).stopServer()
    }
}
