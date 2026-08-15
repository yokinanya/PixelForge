import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val pixelforgeAbi = providers.gradleProperty("pixelforge-abi").orNull
val pixelforgeSigning = providers.gradleProperty("pixelforge-signing").orNull ?: "debug"
val signingPropertiesFile = rootProject.file("key.properties")
val signingProperties = Properties()
val pixelforgeOutputDirectory = layout.buildDirectory.dir("outputs/flutter-apk")
val pixelforgeBuildVariants = listOf("Release")
val pixelforgeFlutterSplitPerAbi = providers.gradleProperty("split-per-abi").orNull == "true"
val releaseBuildRequested = gradle.startParameter.taskNames.any { taskName ->
    taskName.substringAfterLast(':').contains("release", ignoreCase = true)
}

require(pixelforgeSigning == "debug" || pixelforgeSigning == "release") {
    "pixelforge-signing must be either 'debug' or 'release'"
}

if (releaseBuildRequested) {
    require(pixelforgeSigning == "release") {
        "Release builds require custom signing. Pass --android-project-arg=pixelforge-signing=release."
    }
}

if (pixelforgeSigning == "release") {
    require(signingPropertiesFile.isFile) {
        "Missing android/key.properties. Copy android/key.properties.example and configure it."
    }
    signingPropertiesFile.inputStream().use(signingProperties::load)
}

fun requiredSigningProperty(name: String): String {
    val value = signingProperties.getProperty(name)
    require(!value.isNullOrBlank()) {
        "Missing '$name' in android/key.properties"
    }
    return value
}

android {
    namespace = "com.yokinanya.pixelforge"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.yokinanya.pixelforge"
        // 分析引擎在 Rust 侧实现，最低支持 Android 7（API 24）。
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        pixelforgeAbi?.let { abi ->
            ndk {
                abiFilters += abi
            }
        }
    }

    if (pixelforgeAbi == null) {
        splits {
            abi {
                isEnable = true
                reset()
                include("arm64-v8a", "x86_64")
                isUniversalApk = true
            }
        }
    }

    packaging {
        jniLibs {
            if (pixelforgeAbi == "arm64-v8a") {
                excludes += setOf(
                    "**/armeabi-v7a/**",
                    "**/x86/**",
                    "**/x86_64/**",
                )
            }
        }
    }

    signingConfigs {
        if (pixelforgeSigning == "release") {
            create("pixelforgeRelease") {
                keyAlias = requiredSigningProperty("keyAlias")
                keyPassword = requiredSigningProperty("keyPassword")
                storePassword = requiredSigningProperty("storePassword")
                storeFile = file(requiredSigningProperty("storeFile"))
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(
                if (pixelforgeSigning == "release") "pixelforgeRelease" else "debug",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.google.mlkit:text-recognition:16.0.1")
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
    // Use the Play Services model: the bundled face model crashes during the
    // ML Kit startup provider on some Android 15 devices.
    implementation("com.google.android.gms:play-services-mlkit-face-detection:17.1.0")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")
}

val cleanDebugSplitApks = tasks.register("pixelforgeCleanDebugSplitApks") {
    onlyIf { pixelforgeAbi == null && !pixelforgeFlutterSplitPerAbi }
    doLast {
        val outputDirectory = pixelforgeOutputDirectory.get().asFile
        val debugSplitPattern = Regex("app-(?:arm64-v8a|x86_64)-debug\\.apk")
        outputDirectory.listFiles()
            ?.filter { debugSplitPattern.matches(it.name) }
            .orEmpty()
            .forEach { splitApk ->
                check(splitApk.delete()) {
                    "Unable to remove debug split APK: ${splitApk.absolutePath}"
                }
            }
    }
}

tasks.configureEach {
    if (name == "assembleDebug") {
        finalizedBy(cleanDebugSplitApks)
    }
}

pixelforgeBuildVariants.forEach { variantName ->
    val modeName = variantName.lowercase()
    val renameTaskName = "pixelforgeName${variantName}Apks"
    val renameTask = tasks.register(renameTaskName) {
        doLast {
            val outputDirectory = pixelforgeOutputDirectory.get().asFile
            require(outputDirectory.isDirectory) {
                "Flutter APK output directory does not exist: $outputDirectory"
            }

            val sourcePattern = Regex("app(?:-([a-z0-9_-]+))?-$modeName\\.apk")
            val sourceFiles = outputDirectory.listFiles()
                ?.filter { sourcePattern.matches(it.name) }
                .orEmpty()
            require(sourceFiles.isNotEmpty()) {
                "No $modeName APK found in $outputDirectory"
            }

            sourceFiles.forEach { sourceFile ->
                val match = sourcePattern.matchEntire(sourceFile.name)
                    ?: error("Unexpected APK name: ${sourceFile.name}")
                val abi = pixelforgeAbi ?: match.groupValues[1].ifBlank { "universal" }
                val targetFile = outputDirectory.resolve(
                    "PixelForge-${flutter.versionName}-android-$abi.apk",
                )
                Files.copy(
                    sourceFile.toPath(),
                    targetFile.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
                if (sourceFile.name != "app-$modeName.apk") {
                    check(sourceFile.delete()) {
                        "Unable to remove compatibility APK: ${sourceFile.absolutePath}"
                    }
                }
            }
        }
    }

    tasks.configureEach {
        if (name == "assemble$variantName") {
            finalizedBy(renameTask)
        }
    }
}
