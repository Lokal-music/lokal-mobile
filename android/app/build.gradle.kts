plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("dev.flutter.flutter-gradle-plugin")
}

import java.io.File
import java.util.Properties

val keystoreProperties = Properties()
val keystoreFile = rootProject.file("key.properties")
if (keystoreFile.exists()) {
    keystoreFile.inputStream().use { keystoreProperties.load(it) }
}

// CI keeps the keystore in RUNNER_TEMP and passes passwords only via the build
// process environment. Local releases may still use ignored key.properties.
val ciKeystorePath = System.getenv("ANDROID_KEYSTORE_PATH")
val releaseStoreFile = if (ciKeystorePath != null) {
    file(ciKeystorePath)
} else {
    keystoreProperties.getProperty("storeFile")?.let { rootProject.file(it) }
}
fun signingValue(environmentName: String, propertyName: String): String? =
    if (ciKeystorePath != null) System.getenv(environmentName)
    else keystoreProperties.getProperty(propertyName)
val releaseStorePassword = signingValue("ANDROID_KEYSTORE_PASSWORD", "storePassword")
val releaseKeyAlias = signingValue("ANDROID_KEY_ALIAS", "keyAlias")
val releaseKeyPassword = signingValue("ANDROID_KEY_PASSWORD", "keyPassword")

// Fail closed for APK/AAB packaging, including aggregate assemble/bundle tasks.
// Debug builds and the Kotlin configuration guard do not require release keys.
gradle.taskGraph.whenReady {
    if (allTasks.any {
        it.project == project && it.name.contains("Release") &&
            (it.name.startsWith("assemble") || it.name.startsWith("bundle") ||
                it.name.startsWith("package"))
    }) {
        require(releaseStoreFile?.isFile == true &&
            !releaseStorePassword.isNullOrEmpty() && !releaseKeyAlias.isNullOrEmpty() &&
            !releaseKeyPassword.isNullOrEmpty()) {
            "Release signing is required: configure ANDROID_KEYSTORE_PATH, " +
                "ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD " +
                "or an ignored android/key.properties."
        }
    }
}

android {
    // Keep the native namespace stable for the imported Rust/Flutter bridge;
    // applicationId is the public Konnekted identity below.
    namespace = "com.mossapps.flick"
    // permission_handler_android requires API 37. The SDK installation keeps
    // the real platform in android-37.0; the workspace setup normalizes the
    // android-37 alias before building.
    compileSdk = 37
    buildToolsVersion = "36.0.0"
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        // BuildConfig.FLAVOR is surfaced in App Info so users can tell the
        // `full` and `play` builds apart.
        buildConfig = true
    }

    signingConfigs {
        create("release") {
            storeFile = releaseStoreFile
            storePassword = releaseStorePassword
            keyAlias = releaseKeyAlias
            keyPassword = releaseKeyPassword
            enableV1Signing = true
            enableV2Signing = true
        }
    }

    defaultConfig {
        applicationId = "com.lokalkonnekt.konnekted2"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            // Flutter 3.35+ prepopulates all 3 supported ABIs even when the
            // CLI targets android-arm64. Adding to that set does NOT restrict
            // the APK: clear Flutter's defaults before adding the sole ABI.
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }

        externalNativeBuild {
            cmake {
                arguments += "-DANDROID_STL=c++_shared"
            }
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            pickFirsts += listOf("**/libc++_shared.so", "**/libdiscord_partner_sdk.so")
            // Flutter/AGP can merge plugin JNI libraries from every ABI even
            // with defaultConfig.ndk.abiFilters and --target-platform arm64.
            // Filter the actual APK payload before signing; the release
            // verifier must still enforce arm64-v8a as the only packaged ABI.
            excludes += listOf(
                "**/armeabi-v7a/**",
                "**/x86/**",
                "**/x86_64/**",
            )
        }
    }

    // `play` ships to Google Play without MANAGE_EXTERNAL_STORAGE (policy
    // requires MediaStore/SAF for media apps). `full` keeps All Files Access
    // for GitHub Releases and sideload builds. See docs/LIBRARY_SCAN_ARCHITECTURE.md.
    flavorDimensions += "distribution"
    productFlavors {
        create("play") {
            dimension = "distribution"
        }
        create("full") {
            dimension = "distribution"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// Copy libc++_shared.so from NDK before building
tasks.register("copyNdkLibs") {
    description = "Copy libc++_shared.so from Android NDK to jniLibs"
    doLast {
        fun llvmStripFromPath(): String? {
            val executableName =
                if (System.getProperty("os.name").lowercase().contains("win")) {
                    "llvm-strip.exe"
                } else {
                    "llvm-strip"
                }

            return (System.getenv("PATH") ?: "")
                .split(File.pathSeparatorChar)
                .asSequence()
                .map { File(it, executableName) }
                .firstOrNull { it.isFile && it.canExecute() }
                ?.absolutePath
        }

        fun ndkHomeFromLocalProperties(): String? {
            val propsFile = rootProject.file("local.properties")
            if (!propsFile.exists()) return null

            val props = Properties()
            propsFile.inputStream().use { props.load(it) }

            val explicitNdk = props.getProperty("ndk.dir")
            if (!explicitNdk.isNullOrBlank()) {
                return explicitNdk
            }

            val sdkDir = props.getProperty("sdk.dir") ?: return null
            val ndkRoot = File(sdkDir, "ndk")
            if (!ndkRoot.exists()) return null

            return ndkRoot.listFiles()
                ?.filter { it.isDirectory }
                ?.maxByOrNull { it.name }
                ?.absolutePath
        }

        val ndkHome =
            System.getenv("ANDROID_NDK_HOME")
                ?: System.getenv("ANDROID_NDK_ROOT")
                ?: ndkHomeFromLocalProperties()
                ?: throw GradleException(
                    "ANDROID_NDK_HOME/ANDROID_NDK_ROOT is not set and no NDK could be resolved from local.properties",
                )

        val abiToArch = mapOf(
            "arm64-v8a" to "aarch64-linux-android",
        )

        val jniLibsDir = project.file("src/main/jniLibs")
        val llvmStrip = llvmStripFromPath()
        val prebuiltRoots = listOf(
            "toolchains/llvm/prebuilt/windows-x86_64",
            "toolchains/llvm/prebuilt/linux-x86_64",
            "toolchains/llvm/prebuilt/darwin-x86_64",
            "toolchains/llvm/prebuilt/darwin-arm64",
        )

        abiToArch.forEach { (abi, arch) ->
            val abiOutDir = File(jniLibsDir, abi)
            abiOutDir.mkdirs()

            val candidates = mutableListOf<File>()

            prebuiltRoots.forEach { root ->
                candidates += File(ndkHome, "$root/sysroot/usr/lib/$arch/libc++_shared.so")
                candidates += File(ndkHome, "$root/sysroot/usr/lib/$abi/libc++_shared.so")
            }

            // Legacy location (older NDKs)
            candidates += File(ndkHome, "sources/cxx-stl/llvm-libc++/libs/$abi/libc++_shared.so")

            val sourceLib = candidates.firstOrNull { it.exists() }
            if (sourceLib != null) {
                val outputLib = File(abiOutDir, "libc++_shared.so")
                sourceLib.copyTo(outputLib, overwrite = true)

                if (llvmStrip != null) {
                    val sizeBeforeBytes = outputLib.length()
                    val exitCode =
                        ProcessBuilder(llvmStrip, "--strip-debug", outputLib.absolutePath)
                            .redirectErrorStream(true)
                            .start()
                            .waitFor()

                    if (exitCode == 0) {
                        val sizeAfterBytes = outputLib.length()
                        logger.lifecycle(
                            "Stripped libc++_shared.so for $abi: ${sizeBeforeBytes / 1024} KB -> ${sizeAfterBytes / 1024} KB",
                        )
                    } else {
                        logger.warn("Warning: failed to strip libc++_shared.so for $abi")
                    }
                } else {
                    logger.warn("Warning: llvm-strip not found on PATH; leaving libc++_shared.so unstripped for $abi")
                }

                logger.lifecycle("Copied libc++_shared.so for $abi from ${sourceLib.absolutePath}")
            } else {
                logger.warn("Warning: libc++_shared.so not found for $abi in NDK $ndkHome")
            }
        }
    }
}

// Make preBuild depend on copyNdkLibs
tasks.named("preBuild") {
    dependsOn("copyNdkLibs")
}

dependencies {
    // Keep the vendor AAR on the application: AGP rejects direct local AAR
    // dependencies when packaging a Flutter plugin's Android library.
    val discordSdk = rootProject.file("../third_party/mornye_discord/sdk/discord_partner_sdk.aar")
    if (discordSdk.isFile) implementation(files(discordSdk))
    // BitChord's proven YouTube resolver: InnerTubeX handles the live client
    // catalog, cipher transforms and BotGuard PoTokens before media is cached.
    implementation("com.github.MetrolistGroup.innertubex:innertubex-android:v0.7.0")
    implementation("io.ktor:ktor-client-core:3.5.2")
    implementation("io.ktor:ktor-client-okhttp:3.5.2")
    implementation("io.ktor:ktor-client-content-negotiation:3.5.2")
    implementation("io.ktor:ktor-serialization-kotlinx-json:3.5.2")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
    implementation("com.squareup.okhttp3:okhttp:5.3.2")

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.webkit:webkit:1.12.1")
    implementation("androidx.documentfile:documentfile:1.1.0")
    implementation("androidx.media:media:1.7.0")
    // Full-player native music videos: single Media3 clock for separate
    // video-only and audio-only legs, independent of the audio queue.
    implementation("androidx.media3:media3-exoplayer:1.8.0")
    // SoundCloud native streaming can offer AAC through HLS when no progressive MP3 exists.
    implementation("androidx.media3:media3-exoplayer-hls:1.8.0")
    implementation("androidx.media3:media3-ui:1.8.0")
    implementation("androidx.lifecycle:lifecycle-service:2.7.0")
    
    // Jetpack Glance for Widgets
    val glanceVersion = "1.2.0-rc01"
    implementation("androidx.glance:glance-appwidget:$glanceVersion")
    implementation("androidx.glance:glance-material3:$glanceVersion")

    // Google Cast SDK for Chromecast casting
    implementation("com.google.android.gms:play-services-cast-framework:21.5.0")
    implementation("com.google.android.gms:play-services-cast:21.5.0")

    testImplementation("junit:junit:4.13.2")
}
