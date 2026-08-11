package doxa.lang

import com.intellij.openapi.project.Project
import com.intellij.openapi.project.ProjectManagerListener

class DoxaProjectListener : ProjectManagerListener {
    @Suppress("DEPRECATION")
    override fun projectOpened(project: Project) {
        DoxaLspService.getInstance(project).startServer()
    }

    override fun projectClosing(project: Project) {
        DoxaLspService.getInstance(project).stopServer()
    }
}
