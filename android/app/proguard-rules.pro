# Klaxon gallery — ProGuard rules (Phase 3d skeleton).
# minifyEnabled is false for now; these keep the JNI glue intact if it flips on.

# SDL Java shim: called from JNI by libSDL3.so (method names are looked up
# reflectively by the native side).
-keep class org.libsdl.app.** { *; }

# App activity referenced from AndroidManifest.xml by name.
-keep class com.klaxon.gallery.** { *; }

# Any native method must survive shrinking.
-keepclasseswithmembernames class * {
    native <methods>;
}

-dontwarn org.libsdl.app.**
