# Classes reached from native code or by reflection, which R8 cannot see.

# media_kit (RTSP playback): its Android helper is looked up from libmpv through JNI.
-keep class com.alexmercerind.** { *; }

# Flutter's engine references Play Core (deferred components) that this app does not ship.
-dontwarn com.google.android.play.core.**
