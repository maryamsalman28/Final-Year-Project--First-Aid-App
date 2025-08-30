plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after Android/Kotlin
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.burn_severity_app"

    // Flutter plugin injects these
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    defaultConfig {
        applicationId = "com.example.burn_severity_app"
        minSdk = 24
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"

        // Only ship the ABIs you need (reduces size / avoids some conflicts)
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    // Java/Kotlin levels
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    // AGP 8+ packaging DSL
    packaging {
        // Some devices/ROMs can be touchy about META-INF entries
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
        // If you ever see jni duplicate issues, uncomment:
        // jniLibs {
        //     useLegacyPackaging = true
        // }
    }

    buildTypes {
        getByName("release") {
            // Keep this while you’re testing release builds from Flutter
            signingConfig = signingConfigs.getByName("debug")
            // When you enable minify later, add keep rules for PyTorch:
            // isMinifyEnabled = true
            // proguardFiles(
            //     getDefaultProguardFile("proguard-android-optimize.txt"),
            //     "proguard-rules.pro"
            // )
        }
    }
}

dependencies {
    // On-device inference with PyTorch Lite
    implementation("org.pytorch:pytorch_android_lite:1.12.2")
    implementation("org.pytorch:pytorch_android_torchvision_lite:1.12.2")

    // Optional but harmless; helps native loader behavior on some devices.
    // If you want to keep it super minimal, you can remove this line.
    implementation("com.facebook.soloader:nativeloader:0.10.5")
}

flutter {
    source = "../.."
}
