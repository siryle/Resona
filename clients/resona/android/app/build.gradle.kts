plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.resona.client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "app.resona.client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (!System.getenv("RESONA_ANDROID_KEYSTORE").isNullOrEmpty()) {
            create("distribution") {
                storeFile = file(System.getenv("RESONA_ANDROID_KEYSTORE"))
                storePassword = System.getenv("RESONA_ANDROID_STORE_PASSWORD")
                keyAlias = System.getenv("RESONA_ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("RESONA_ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Without distribution credentials, produce a sideload-only preview build.
            signingConfig = signingConfigs.findByName("distribution") ?: signingConfigs.getByName("debug")
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
