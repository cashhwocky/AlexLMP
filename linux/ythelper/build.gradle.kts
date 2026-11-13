// AlexLMP's YouTube Music bridge (the same YtMusicBridge.kt the phone app
// uses) built for desktop Java, talking to the app over stdin/stdout.
plugins {
    kotlin("jvm") version "1.9.24"
    id("com.gradleup.shadow") version "8.3.5"
    application
}

dependencies {
    implementation("com.github.teamnewpipe:NewPipeExtractor:v0.26.5")
    implementation("org.json:json:20240303")
}

kotlin { jvmToolchain(17) }

application { mainClass.set("com.alexlmp.app.MainKt") }

tasks.shadowJar {
    archiveFileName.set("ythelper.jar")
}
