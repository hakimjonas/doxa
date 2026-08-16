import org.jetbrains.intellij.platform.gradle.TestFrameworkType

plugins {
    id("org.jetbrains.intellij.platform") version "2.5.0"
    kotlin("jvm") version "2.1.20"
}

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")

    intellijPlatform {
        create("IC", "2025.1")
        testFramework(TestFrameworkType.Platform)
    }
}

tasks.test {
    useJUnit()
    systemProperty("doxa.executable", System.getenv("DOXA_EXECUTABLE") ?: "doxa")
}

intellijPlatform {
    pluginConfiguration {
        name = "Doxa"
        version = providers.gradleProperty("pluginVersion").get()

        ideaVersion {
            sinceBuild = providers.gradleProperty("pluginSinceBuild").get()
            untilBuild = providers.gradleProperty("pluginUntilBuild").orNull
        }

        changeNotes = "LSP client for Doxa language server. Works in all JetBrains IDEs."

        vendor {
            name = "Doxa"
            url = "https://github.com/hakimjonas/doxa"
        }
    }

    publishing {
        token = providers.environmentVariable("JETBRAINS_MARKETPLACE_TOKEN")
    }
}
