import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import com.vanniktech.maven.publish.JavadocJar
import com.vanniktech.maven.publish.SourcesJar
import java.security.MessageDigest
import javax.inject.Inject
import org.gradle.process.ExecOperations
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("com.vanniktech.maven.publish")
}

// eSpeak NG (GPL-3.0-or-later) as a SentenceVoice and a Phonemizer. Unlike every other speechwarp module this one
// is GPL-3.0-or-later, and so is an app that uses it: see README.md and COPYING.
//
// eSpeak is compiled from the third_party/espeak-ng submodule for each ABI by src/main/cpp/CMakeLists.txt. Its data
// is compiled on this computer, by upstream's espeak-ng command built for it from the same CMake project, and goes
// into the AAR's assets (compile-espeak-data.sh).

// The version lives in the public C header, as it does for every other build of the library.
val header = rootDir.resolve("../../include/speechwarp.h").readText()
val libraryVersion = Regex("#define SPEECHWARP_VERSION \"(.*)\"").find(header)!!.groupValues[1]
val espeakSource = rootDir.resolve("../../third_party/espeak-ng")

group = "io.github.fredgaffey"
version = libraryVersion

android {
    namespace = "io.github.fredgaffey.speechwarp.voice.espeak"
    compileSdk = 36
    ndkVersion = "27.1.12297006"

    defaultConfig {
        minSdk = 21
        consumerProguardFiles("consumer-rules.pro")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        externalNativeBuild {
            cmake {
                arguments += "-DCMAKE_BUILD_TYPE=Release"
            }
        }
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64", "x86")
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    // Android 14 and later refuse to install a test APK that targets less than API 24.
    testOptions {
        targetSdk = 36
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
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    // The instrumented tests also speak Kokoro with this module's phonemizer. Only the tests: the published module
    // does not depend on Kokoro, nor Kokoro on it.
    androidTestImplementation(project(":speechwarp-voice-kokoro"))
}

// The same CMake project built for this computer: upstream's espeak-ng command, which compiles the data, and the JNI
// library, for the unit tests on this computer's JVM (when CMake finds a JDK).
val hostNativeDir = layout.buildDirectory.dir("host-native")
val buildHostNative by tasks.registering {
    val source = file("src/main/cpp")
    inputs.dir(source)
    inputs.dir(espeakSource.resolve("src"))
    outputs.dir(hostNativeDir)
    doLast {
        val out = hostNativeDir.get().asFile
        providers.exec { commandLine("cmake", "-S", source.path, "-B", out.path, "-DCMAKE_BUILD_TYPE=Release") }.result.get()
        providers.exec { commandLine("cmake", "--build", out.path, "--config", "Release", "--parallel") }.result.get()
    }
}

/** Compiles eSpeak's data with compile-espeak-data.sh, into assets/speechwarp-espeak with a stamp (its hash) beside it. */
abstract class CompileEspeakData : DefaultTask() {
    @get:InputFile abstract val script: RegularFileProperty
    @get:InputDirectory abstract val dictionaries: DirectoryProperty
    @get:InputDirectory abstract val hostNative: DirectoryProperty
    @get:OutputDirectory abstract val outputDirectory: DirectoryProperty
    @get:Inject abstract val exec: ExecOperations

    @TaskAction
    fun compile() {
        val out = outputDirectory.get().asFile.resolve("speechwarp-espeak")
        out.deleteRecursively()
        out.mkdirs()
        exec.exec {
            commandLine("sh", script.get().asFile.path, hostNative.get().asFile.resolve("espeak-ng").path, out.path)
        }
        // The library copies the data to the app's files folder only when this changes.
        val digest = MessageDigest.getInstance("SHA-256")
        val data = out.resolve("espeak-ng-data")
        data.walkTopDown().filter { it.isFile }.sortedBy { it.relativeTo(data).invariantSeparatorsPath }.forEach {
            digest.update(it.relativeTo(data).invariantSeparatorsPath.toByteArray())
            digest.update(0)
            digest.update(it.readBytes())
        }
        out.resolve("stamp").writeText(digest.digest().joinToString("") { "%02x".format(it) } + "\n")
    }
}

val compileEspeakData by tasks.registering(CompileEspeakData::class) {
    dependsOn(buildHostNative)
    script.set(layout.projectDirectory.file("compile-espeak-data.sh"))
    // Only what the data is made from, not the whole submodule.
    dictionaries.set(espeakSource.resolve("dictsource"))
    inputs.dir(espeakSource.resolve("phsource"))
    inputs.dir(espeakSource.resolve("espeak-ng-data"))
    hostNative.set(hostNativeDir)
    outputDirectory.set(layout.buildDirectory.dir("espeak-assets"))
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(compileEspeakData, CompileEspeakData::outputDirectory)
    }
}

tasks.withType<Test>().configureEach {
    dependsOn(buildHostNative, compileEspeakData)
    systemProperty("java.library.path", hostNativeDir.get().asFile.path)
    systemProperty("speechwarp.espeak.data", layout.buildDirectory.dir("espeak-assets/speechwarp-espeak/espeak-ng-data").get().asFile.path)
}

// eSpeak's licences and speechwarp's travel in the AAR (inside classes.jar).
val licenceFiles = layout.buildDirectory.dir("licence-resources")
val collectLicences by tasks.registering(Sync::class) {
    into(licenceFiles)
    from(projectDir) {
        include("COPYING")
        into("META-INF/licenses/speechwarp-voice-espeak")
    }
    from(espeakSource) {
        include("COPYING", "COPYING.APACHE", "COPYING.BSD2", "COPYING.UCD")
        into("META-INF/licenses/speechwarp-voice-espeak/espeak-ng")
    }
    from(rootDir.resolve("../..")) {
        include("LICENSE", "NOTICE")
        into("META-INF/licenses/speechwarp-voice-espeak/speechwarp")
    }
}
android.sourceSets.getByName("main").resources.srcDir(licenceFiles)
tasks.matching { it.name.endsWith("JavaRes") }.configureEach { dependsOn(collectLicences) }

// Published to Maven Central as io.github.fredgaffey:speechwarp-voice-espeak, beside speechwarp-voice, which it
// depends on. The sources and javadoc JARs and the POM details are what Central requires.
mavenPublishing {
    configure(AndroidSingleVariantLibrary(variant = "release", sourcesJar = SourcesJar.Sources(), javadocJar = JavadocJar.Javadoc()))
    coordinates("io.github.fredgaffey", "speechwarp-voice-espeak", libraryVersion)
    publishToMavenCentral(automaticRelease = true)
    pom {
        name.set("speechwarp-voice-espeak")
        description.set(
            "eSpeak NG on Android as a voice and a phonemizer for speechwarp-voice. GPL-3.0-or-later, unlike the " +
                "other speechwarp libraries: an app that uses it must be distributed under the GPL-3.0 too."
        )
        inceptionYear.set("2026")
        url.set("https://github.com/fredgaffey/speechwarp")
        licenses {
            license {
                name.set("GPL-3.0-or-later")
                url.set("https://www.gnu.org/licenses/gpl-3.0.txt")
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
