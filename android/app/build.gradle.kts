plugins {
    id("com.android.application")
    // Chaquopy (CPython embed) for the affine StitchMode. After AGP.
    id("com.chaquo.python")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "at.sciens.gimbal_controller"
    compileSdk = flutter.compileSdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Javalin/Jetty 11 + graphql-java 22 use newer JDK APIs that D8 can
        // only dex with core-library desugaring (same as petzvalStudio).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "at.sciens.gimbal_controller"
        // cv2 4.5.1.48 wheel needs >= 24; Jetty 11 (Javalin's server) needs
        // >= 26 — so the floor is 26 (matches petzvalStudio).
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = 33
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true

        // arm64-v8a only — the phone target. Chaquopy fetches its native
        // Python wheels (numpy, cv2) for exactly these ABIs.
        ndk {
            abiFilters += listOf("arm64-v8a")
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

chaquopy {
    defaultConfig {
        version = "3.10"
        pip {
            // numpy + cv2 4.5.1.48 installed normally so opencv pulls its
            // native deps (libjpeg/libpng/openblas/...). `stitching` is NOT
            // pip-installed — it's vendored under src/main/python/stitching/,
            // which keeps its numba-bound largestinteriorrectangle dep out.
            // (See chaquopy_spike — proven on-device.)
            install("numpy")
            install("opencv-python==4.5.1.48")
        }
    }
}

dependencies {
    // The in-process stitch server, built from source (Javalin + graphql-java
    // + jackson + slf4j come transitively as its `api` deps).
    implementation(project(":panostitch-renderer"))
    // Required by isCoreLibraryDesugaringEnabled = true.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}

flutter {
    source = "../.."
}
