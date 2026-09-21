plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.yeyjk.flv_hevc_player"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    lint {
        // 关闭 release 构建的 lint 检查（lintVital 在部分 Windows 环境被文件锁卡死）
        checkReleaseBuilds = false
        abortOnError = false
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.yeyjk.flv_hevc_player"
        // 手机版 minSdk 24（video_player/fvp 要求）
        minSdk = 24
        targetSdk = 34
        // 注意：不写 ndk.abiFilters。使用 --split-per-abi 构建时由 Gradle splits
        // 自动按 fvp 支持的 ABI 拆分（arm64-v8a / armeabi-v7a / x86_64 等），
        // 显式 abiFilters 会与 splits 冲突导致构建失败。
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
    // 注意：此处不写任何 minSdk 赋值。flutter tool 迁移会把
    // `minSdk(Version) = 16~23` 强制替换为 `minSdk = flutter.minSdkVersion`，
    // 而 Flutter 3.47 的 flutter.minSdkVersion 默认值正好是 23（Android 6.0 电视兼容）。
    // defaultConfig 里 `minSdk = flutter.minSdkVersion` 即为目标值，无需覆盖。
}
