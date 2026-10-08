plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// ./gradlew assembleRelease -Prelay=https://help.example.com   (the address the app offers by default; it can be changed in the app)
val relayUrl = (project.findProperty("relay") as String?) ?: "https://nl-1.leet-prop.ru:8444"

android {
    namespace = "app.helpermcp"
    compileSdk = 35
    defaultConfig {
        applicationId = "app.helpermcp"
        minSdk = 30            // AccessibilityService.takeScreenshot needs Android 11
        targetSdk = 35
        versionCode = 19
        versionName = "0.5.0"
        buildConfigField("String", "RELAY", "\"$relayUrl\"")
    }
    buildFeatures { buildConfig = true }
    buildTypes {
        release { isMinifyEnabled = false; signingConfig = signingConfigs.getByName("debug") }   // sideloaded APK; replace with your own key for a stable update channel
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
}
