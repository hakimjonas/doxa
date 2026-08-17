package doxa.lang

import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.project.Project

object DoxaNotifications {
    fun serverError(project: Project, message: String) {
        NotificationGroupManager.getInstance()
            .getNotificationGroup("Doxa Language Server")
            .createNotification("Doxa language server", message, NotificationType.ERROR)
            .notify(project)
    }
}
