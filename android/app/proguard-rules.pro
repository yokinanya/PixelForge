# ML Kit discovers feature registrars from Manifest metadata at runtime.
# Keep the registrar implementations and their factory methods intact when
# Flutter enables R8 for Release builds.
-keep class * implements com.google.firebase.components.ComponentRegistrar {
    *;
}
