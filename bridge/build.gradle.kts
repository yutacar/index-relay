plugins { kotlin("multiplatform") version "2.2.20" }
kotlin {
    iosArm64 { binaries.framework { baseName = "IndexReceiverBridge"; isStatic = true } }
    iosSimulatorArm64 { binaries.framework { baseName = "IndexReceiverBridge"; isStatic = true } }
    sourceSets {
        iosMain.dependencies {
            implementation("io.github.coredevices.haversine:haversine:2541a33")
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
        }
    }
}
