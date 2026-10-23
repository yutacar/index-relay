import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    buildFeatures { buildConfig = true; resValues = true }
    namespace = "dev.example.index_relay_probe"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.example.index_relay_probe"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("boolean", "PREVIEW", "false")
    }
    val productionId = providers.gradleProperty("indexApplicationId").orNull
    val unsignedReview = providers.gradleProperty("indexUnsigned").orNull == "true"
    val signingFile = rootProject.file("release-signing.local.properties")
    if (!unsignedReview && signingFile.isFile) {
        val signing = Properties().apply { signingFile.inputStream().use { load(it) } }
        signingConfigs.create("distribution") {
            storeFile = rootProject.file(requireNotNull(signing.getProperty("storeFile")))
            keyAlias = requireNotNull(signing.getProperty("keyAlias"))
            storePassword = requireNotNull(System.getenv("INDEX_RELAY_KEYSTORE_PASSWORD")) { "Set keystore password in environment" }
            keyPassword = requireNotNull(System.getenv("INDEX_RELAY_KEY_PASSWORD")) { "Set key password in environment" }
        }
    }
    flavorDimensions += "purpose"
    productFlavors {
        create("preview") {
            dimension = "purpose"
            buildConfigField("boolean", "PREVIEW", "true")
            resValue("string", "app_name", "Index Relay Preview")
            signingConfig = signingConfigs.getByName("debug")
        }
        create("production") {
            dimension = "purpose"
            minSdk = 31
            applicationId = productionId ?: "dev.example.indexrelay.unconfigured"
            resValue("string", "app_name", "Index Relay")
            signingConfig = if(unsignedReview) null else signingConfigs.findByName("distribution")
        }
    }
    tasks.configureEach {
        if (name == "preProductionReleaseBuild") doFirst {
            require(productionId != null && Regex("^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$").matches(productionId)) { "Explicit indexApplicationId is required" }
            require(unsignedReview || signingConfigs.findByName("distribution") != null) { "Configure distribution signing or indexUnsigned=true; debug signing is forbidden" }
        }
    }

    val probeProperties = Properties().apply {
        rootProject.file("local.properties").inputStream().use { load(it) }
    }
    defaultConfig {
        ndk {
            abiFilters.clear()
            abiFilters += (providers.gradleProperty("indexAbis").orNull ?: "arm64-v8a").split(',').also { values ->
                require(values.isNotEmpty() && values.all { it in listOf("arm64-v8a", "x86_64") })
            }
        }
        externalNativeBuild { cmake {
            arguments += "-DWHISPER_SOURCE_DIR=${probeProperties.getProperty("whisper.source") ?: error("Set whisper.source in local.properties") }"
        } }
    }
    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt"); version = "3.22.1" } }
    buildTypes {
        release { signingConfig = null } // Flavor provides a real key or an explicitly unsigned review build.
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

dependencies {
    implementation("co.touchlab:kermit:2.0.6")
    implementation("androidx.work:work-runtime-ktx:2.11.2")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    implementation("io.github.coredevices.haversine:haversine:2541a33")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
}

// Coordinates only: no local paths, credentials or dependency contents in the report.
tasks.register("writeDependencyInventory") {
    doLast {
        val modules = configurations.getByName("productionReleaseRuntimeClasspath").incoming.resolutionResult.allComponents
            .mapNotNull { it.id as? org.gradle.api.artifacts.component.ModuleComponentIdentifier }
            .map { mapOf("group" to it.group, "name" to it.module, "version" to it.version) }.sortedBy { "${it["group"]}:${it["name"]}" }
        val output = layout.buildDirectory.file("reports/index-relay-dependencies.json").get().asFile
        output.parentFile.mkdirs(); output.writeText(groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(modules)))
    }
}
