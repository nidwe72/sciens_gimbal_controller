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
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Javalin/Jetty 11 + graphql-java 22 use newer JDK APIs that D8 can
        // only dex with core-library desugaring (same as petzvalStudio).
        isCoreLibraryDesugaringEnabled = true
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    defaultConfig {
        applicationId = "at.sciens.gimbal_controller"
        // OpenPano needs >= 21; cv2 4.5.1.48 wheel needs >= 24; Jetty 11
        // (Javalin's server, used by the affine StitchMode) needs >= 26 — so
        // the floor is 26 (matches petzvalStudio).
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
    // The forked in-process stitch server (thin jar; heavy deps pulled below).
    implementation(files("libs/panostitch-renderer.jar"))
    // Embedded HTTP + GraphQL — same versions the renderer jar compiled against.
    implementation("io.javalin:javalin:6.3.0")
    implementation("com.graphql-java:graphql-java:22.3")
    implementation("com.fasterxml.jackson.core:jackson-databind:2.18.0")
    implementation("org.reactivestreams:reactive-streams:1.0.4")
    implementation("org.slf4j:slf4j-simple:2.0.16")
    // Required by isCoreLibraryDesugaringEnabled = true.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}

flutter {
    source = "../.."
}
