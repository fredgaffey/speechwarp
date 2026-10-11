// The Android side of speechwarp_voice: a thin layer over the Kotlin library io.github.fredgaffey:speechwarp-voice
// (bindings/android/speechwarp-voice in the repository), which does the reading. This plays what it reads through
// an AudioTrack and reports the position to Dart.
//
// The library comes from Maven Central at the same version as this package. To build against the repository's own
// modules instead (before a release, or while changing them), the app's settings.gradle(.kts) includes
// bindings/android as a composite build, as this package's example does; Gradle then substitutes the modules for
// the artifacts.

group = "io.github.fredgaffey.speechwarp_voice"
version = "0.3.7"

// The version of the speechwarp Android libraries: the same release as this package.
val speechwarpVersion = "0.3.7"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "io.github.fredgaffey.speechwarp_voice"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        // Flutter's own minimum. speechwarp-voice itself asks for 21, speechwarp-voice-kokoro for 24.
        minSdk = 24
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // The reader, the voice cache and Android's voices; brings the speechwarp core (speechwarp-android) with it.
    implementation("io.github.fredgaffey:speechwarp-voice:$speechwarpVersion")
}
