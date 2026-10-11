import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import com.vanniktech.maven.publish.JavadocJar
import com.vanniktech.maven.publish.SourcesJar
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("com.vanniktech.maven.publish")
}

// Kokoro-82M, a neural voice, on ONNX Runtime's CPU, as a SentenceVoice. Pure Kotlin: the native code is ONNX
// Runtime's own AAR. It takes any Phonemizer and does not depend on the GPL eSpeak module.

// The version lives in the public C header, as it does for every other build of the library.
val header = rootDir.resolve("../../include/speechwarp.h").readText()
val libraryVersion = Regex("#define SPEECHWARP_VERSION \"(.*)\"").find(header)!!.groupValues[1]

group = "io.github.fredgaffey"
version = libraryVersion

android {
    namespace = "io.github.fredgaffey.speechwarp.voice.kokoro"
    compileSdk = 36

    defaultConfig {
        // ONNX Runtime's AAR needs Android 7.0.
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_11)
    }
}

dependencies {
    api(project(":speechwarp-voice"))
    // The same ONNX Runtime as the C# package (Microsoft.ML.OnnxRuntime 1.23.2). CPU only.
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.23.2")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}

// Published to Maven Central as io.github.fredgaffey:speechwarp-voice-kokoro, beside speechwarp-voice, which it
// depends on. The sources and javadoc JARs and the POM details are what Central requires.
mavenPublishing {
    configure(AndroidSingleVariantLibrary(variant = "release", sourcesJar = SourcesJar.Sources(), javadocJar = JavadocJar.Javadoc()))
    coordinates("io.github.fredgaffey", "speechwarp-voice-kokoro", libraryVersion)
    publishToMavenCentral(automaticRelease = true)
    pom {
        name.set("speechwarp-voice-kokoro")
        description.set("Kokoro-82M neural text-to-speech on ONNX Runtime's CPU, as a voice for speechwarp-voice on Android")
        inceptionYear.set("2026")
        url.set("https://github.com/fredgaffey/speechwarp")
        licenses {
            license {
                name.set("Apache-2.0")
                url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                distribution.set("repo")
            }
        }
        developers {
            developer {
                id.set("fredgaffey")
                name.set("Fred Gaffey")
                url.set("https://github.com/fredgaffey")
            }
        }
        scm {
            url.set("https://github.com/fredgaffey/speechwarp")
            connection.set("scm:git:https://github.com/fredgaffey/speechwarp.git")
            developerConnection.set("scm:git:ssh://git@github.com/fredgaffey/speechwarp.git")
        }
    }

    // Signed only when the release workflow supplies a key (see the speechwarp module).
    if (providers.gradleProperty("signingInMemoryKey").isPresent) {
        signAllPublications()
    }
}
