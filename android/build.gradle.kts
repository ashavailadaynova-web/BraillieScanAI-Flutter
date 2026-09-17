import org.gradle.api.Project

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

fun applyNamespaceFallback(sub: Project) {
    val android = sub.extensions.findByName("android") ?: return
    val getter = android::class.java.methods
        .firstOrNull { it.name == "getNamespace" && it.parameterCount == 0 } ?: return
    val currentNs = getter.invoke(android) as? String
    if (currentNs == null) {
        val groupStr = sub.group.toString()
        val fallback = groupStr.takeIf { it.isNotBlank() && it != "unspecified" }
            ?: "com.example.${sub.name.replace(":", "")}"
        try {
            android::class.java
                .getMethod("setNamespace", String::class.java)
                .invoke(android, fallback)
            println("--> PAKAI namespace fallback untuk :${sub.name} = $fallback")
        } catch (e: Exception) {
            println("--> GAGAL set namespace untuk :${sub.name}: ${e.message}")
        }
    }
}

subprojects {
    val sub = this
    sub.pluginManager.withPlugin("com.android.library") {
        applyNamespaceFallback(sub)
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
