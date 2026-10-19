plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "ru.sru.sru"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "ru.sru.sru"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // 26: Process.isAlive / waitFor(timeout) в SruVpnService.
        minSdk = maxOf(26, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Ядро собирается только под arm64 (см. android/core/build.sh).
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    // libsrucore.so — исполняемый файл ядра: его нужно распаковать
    // в nativeLibraryDir, чтобы система разрешила его запуск.
    packaging {
        jniLibs {
            useLegacyPackaging = true
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

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Ядро Xray (Go) и geo-базы собираются перед сборкой APK, если изменились исходники.
val buildCore by tasks.registering(Exec::class) {
    val core = rootProject.file("core")
    inputs.files(fileTree(core) { include("*.go", "go.mod", "go.sum", "build.sh") })
    outputs.file("src/main/jniLibs/arm64-v8a/libsrucore.so")
    outputs.files("src/main/assets/geo/geoip.dat", "src/main/assets/geo/geosite.dat")
    commandLine("bash", core.resolve("build.sh").path)
}

tasks.named("preBuild") {
    dependsOn(buildCore)
}
