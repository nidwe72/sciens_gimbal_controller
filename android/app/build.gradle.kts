plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "at.sciens.gimbal_controller"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    defaultConfig {
        applicationId = "at.sciens.gimbal_controller"
        // OpenPano (Phase 6 stitch) requires minSdk >= 21.
        minSdk = maxOf(flutter.minSdkVersion, 21)
        targetSdk = 33
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
                arguments += "-DANDROID_STL=c++_shared"
                // Build the OpenPano stitch shim for arm64 only (the
                // SCORP-control phone target). Flutter owns ndk.abiFilters,
                // but this controls the native build directly.
                abiFilters("arm64-v8a")
            }
        }
    }

    // Phase 6: ship arm64-v8a only — strip any other-ABI libs the
    // Flutter toolchain / plugins bundle, to bound APK size.
    packaging {
        jniLibs {
            excludes += setOf(
                "**/armeabi-v7a/**",
                "**/x86/**",
                "**/x86_64/**",
            )
        }
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
}
