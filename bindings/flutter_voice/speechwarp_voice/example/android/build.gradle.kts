allprojects {
    repositories {
        // The repository's own Android libraries (bindings/android), published to this computer's Maven repository by
        // `./gradlew publishToMavenLocal` there, so that the example runs the Kotlin code beside it rather than a
        // release from Maven Central. Only speechwarp's group is taken from there. An app outside the repository
        // leaves this out. (A composite build cannot do it: bindings/android uses another version of the Android
        // Gradle plugin, and Gradle refuses two in one build.)
        mavenLocal {
            content { includeGroup("io.github.fredgaffey") }
        }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
