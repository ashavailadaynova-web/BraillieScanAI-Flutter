import org.gradle.api.Project
import org.gradle.api.file.Directory

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir = newBuildDir.dir(project.name)
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
    if (currentNs.isNullOrBlank()) {
        val cleanName = sub.name.replace(":", "").replace("-", "_")
        val fallback = when (cleanName) {
            "image_picker_android" -> "io.flutter.plugins.imagepicker"
            "camera_android_camerax" -> "io.flutter.plugins.camerax"
            "flutter_plugin_android_lifecycle" -> "io.flutter.plugins.flutter_plugin_android_lifecycle"
            "image_cropper" -> "vn.hunghd.flutter.plugins.imagecropper"
            "tflite_flutter" -> "org.tensorflow.tflite_flutter"
            "jni" -> "com.github.dart_lang.jni"
            "jni_flutter" -> "com.github.dart_lang.jni_flutter"
            else -> "com.braillescan.plugin.$cleanName"
        }
        try {
            android::class.java
                .getMethod("setNamespace", String::class.java)
                .invoke(android, fallback)
            println("--> Sukses set namespace unik :${sub.name} = $fallback")
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