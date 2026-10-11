# ONNX Runtime's native code makes and reads its Java objects by name, and its AAR brings no rules of its own, so
# an app shrunk with R8 must keep them.
-keep class ai.onnxruntime.** { *; }
