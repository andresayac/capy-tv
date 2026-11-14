import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing key, kept out of the repository (see README). Without it release builds
// are signed with the debug key, which is fine for local testing but not for distribution.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

android {
    namespace = "com.capytv.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // The player's native libraries (about 30 MB per processor type) go compressed: the APK is
    // passed around and sideloaded, not served by a store, so half the download beats installing
    // a little faster
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    // Built for some processors only (--target-platform), the player's libraries follow. They come
    // as Java resources inside media_kit's jars, which ABI filters do not reach: without this they
    // came for every processor, and a device of another kind would install the APK and then fail
    // to start it, for want of Flutter's own libraries
    (project.findProperty("target-platform") as String?)?.let { targets ->
        val abis = mapOf("android-arm" to "armeabi-v7a", "android-arm64" to "arm64-v8a", "android-x64" to "x86_64")
        val others = listOf("armeabi-v7a", "arm64-v8a", "x86_64", "x86") - targets.split(",").mapNotNull { abis[it.trim()] }
        packaging {
            resources { excludes += others.map { "lib/$it/**" } }
            jniLibs { excludes += others.map { "lib/$it/**" } }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Changing it makes another app: Android installs it beside the old one, with its own data
        // (README, "Updates from your server")
        applicationId = "com.capytv.app"
        // Android 7.0, fixed: a Flutter update raising it would leave out the old TV boxes the
        // 32-bit APK is for (README, "Android, Android TV and Fire TV")
        minSdk = 24
        // Fixed, as a Flutter update must not raise it unnoticed. Before 37: the local network is
        // to be asked for at run time (ACCESS_LOCAL_NETWORK: Chromecast, its relay, the phone's
        // page), background audio has stricter rules, and landscape is no longer honoured on
        // tablets (AndroidManifest.xml)
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystoreProperties.containsKey("storeFile")) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        // Beside the installed app: a debug build of the same id would make Flutter uninstall it
        debug {
            applicationIdSuffix = ".test"
        }
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
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
