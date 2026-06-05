// Built from source as part of the Android Gradle build (included from
// android/settings.gradle.kts), so nothing binary is committed. Replaces the
// former Maven pom + checked-in libs/panostitch-renderer.jar.
plugins {
    `java-library`
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

dependencies {
    // `api`, not `implementation`: the Android app (BackendChannel) compiles
    // against io.javalin.Javalin, so these must be on the app's compile
    // classpath transitively.
    api("io.javalin:javalin:6.3.0")
    api("com.graphql-java:graphql-java:22.3")
    api("com.fasterxml.jackson.core:jackson-databind:2.18.0")
    api("org.reactivestreams:reactive-streams:1.0.4")
    api("org.slf4j:slf4j-api:2.0.16")
    runtimeOnly("org.slf4j:slf4j-simple:2.0.16")
}
