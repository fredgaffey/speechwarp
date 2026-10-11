// The Android side of speechwarp_voice_kokoro: the Kotlin library io.github.fredgaffey:speechwarp-voice-kokoro
// (bindings/android/speechwarp-voice-kokoro in the repository, which brings ONNX Runtime) and the provider class
// through which speechwarp_voice makes Kokoro voices.
//
// The library comes from Maven Central at the same version as this package; see speechwarp_voice's build file for
// building against the repository's own modules instead.

group = "io.github.fredgaffey.speechwarp_voice_kokoro"
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
    namespace = "io.github.fredgaffey.speechwarp_voice_kokoro"

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
        // Flutter's own minimum, and ONNX Runtime's.
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Kokoro on ONNX Runtime's CPU; brings speechwarp-voice, whose VoiceFactory and Phonemizer the provider uses.
    implementation("io.github.fredgaffey:speechwarp-voice-kokoro:$speechwarpVersion")
}
