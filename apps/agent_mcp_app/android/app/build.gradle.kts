import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreDir: File = rootProject.file("keystore")
val keystoreProps = Properties()
var loadedPropsFile: File? = null

for (candidate in listOf(
    File(keystoreDir, "r0s.properties"),
    File(keystoreDir, "release.properties"),
    rootProject.file("key.properties"),
)) {
    if (candidate.isFile) {
        candidate.inputStream().use { keystoreProps.load(it) }
        loadedPropsFile = candidate
        break
    }
}

val rawStorePath = keystoreProps.getProperty("storeFile")?.trim().orEmpty()
val resolvedStoreFile: File? = if (rawStorePath.isNotEmpty()) {
    val direct = File(rawStorePath)
    when {
        direct.isAbsolute && direct.isFile -> direct
        loadedPropsFile != null && File(loadedPropsFile!!.parentFile, rawStorePath).isFile ->
            File(loadedPropsFile!!.parentFile, rawStorePath)
        File(keystoreDir, rawStorePath).isFile -> File(keystoreDir, rawStorePath)
        rootProject.file(rawStorePath).isFile -> rootProject.file(rawStorePath)
        else -> null
    }
} else {
    null
}

val resolvedStorePassword = keystoreProps.getProperty("storePassword")?.trim().orEmpty()
val resolvedKeyAlias = keystoreProps.getProperty("keyAlias")?.trim().orEmpty()
val resolvedKeyPassword = keystoreProps.getProperty("keyPassword")?.trim().orEmpty()

val hasFixedKeystore = resolvedStoreFile != null &&
    resolvedStorePassword.isNotEmpty() &&
    resolvedKeyAlias.isNotEmpty() &&
    resolvedKeyPassword.isNotEmpty()

if (hasFixedKeystore) {
    println("[Signing] Using fixed keystore: ${resolvedStoreFile!!.name} (alias=$resolvedKeyAlias)")
} else {
    println("[Signing] No keystore/r0s.properties or key.properties found; falling back to debug keystore.")
}

android {
    namespace = "com.iamr0s.agent_mcp_app"
    compileSdk = flutter.compileSdkVersion

    buildFeatures {
        aidl = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.iamr0s.agent_mcp_app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasFixedKeystore) {
            getByName("debug") {
                storeFile = resolvedStoreFile
                storePassword = resolvedStorePassword
                keyAlias = resolvedKeyAlias
                keyPassword = resolvedKeyPassword
            }
            create("release") {
                storeFile = resolvedStoreFile
                storePassword = resolvedStorePassword
                keyAlias = resolvedKeyAlias
                keyPassword = resolvedKeyPassword
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasFixedKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
}

flutter {
    source = "../.."
}
