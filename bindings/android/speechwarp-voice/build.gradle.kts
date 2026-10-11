import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import com.vanniktech.maven.publish.JavadocJar
import com.vanniktech.maven.publish.SourcesJar
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("com.vanniktech.maven.publish")
}

// Text read aloud by any engine, sped up by speechwarp: the live reader, the disk cache and Android's own voices.
// Pure Kotlin: the native code is in the speechwarp module it depends on.

// The version lives in the public C header, as it does for every other build of the library.
val header = rootDir.resolve("../../include/speechwarp.h").readText()
val libraryVersion = Regex("#define SPEECHWARP_VERSION \"(.*)\"").find(header)!!.groupValues[1]

group = "io.github.fredgaffey"
version = libraryVersion

android {
    namespace = "io.github.fredgaffey.speechwarp.voice"
    compileSdk = 36

    defaultConfig {
        minSdk = 21
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
    // VoicedText.configure hands out the SpeechwarpStream, so the core is part of this module's API.
    api(project(":speechwarp"))
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
}

// The unit tests run on this computer's JVM against the speechwarp module's host build of the native library.
val speechwarpProject = project(":speechwarp")
tasks.withType<Test>().configureEach {
    dependsOn(":speechwarp:buildHostJni")
    systemProperty("java.library.path", speechwarpProject.layout.buildDirectory.dir("host-jni").get().asFile.path)
}

// Published to Maven Central as io.github.fredgaffey:speechwarp-voice, beside speechwarp-android, which it
// depends on. The sources and javadoc JARs and the POM details are what Central requires.
mavenPublishing {
    configure(AndroidSingleVariantLibrary(variant = "release", sourcesJar = SourcesJar.Sources(), javadocJar = JavadocJar.Javadoc()))
    coordinates("io.github.fredgaffey", "speechwarp-voice", libraryVersion)
    publishToMavenCentral(automaticRelease = true)
    pom {
        name.set("speechwarp-voice")
        description.set("Text read aloud on Android by any voice, sentence by sentence, sped up by speechwarp")
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
