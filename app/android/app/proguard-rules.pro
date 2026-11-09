# ============================================================================
# R8 keep 规则 — 为什么需要这个文件
#
# mobile_scanner 5.2.3 自带的 consumer 规则是 `-keep class com.google.mlkit.* { *; }`，
# ProGuard 的单个 `*` 不跨包边界，因此 com.google.mlkit.vision.barcode.internal.**
# 与 com.google.android.gms.internal.mlkit_vision_barcode{,_bundled}.** 全被改名，
# MLKit 运行时用反射按"原始类名"加载 → ClassNotFoundException → 被内部 catch 成
# MobileScannerException: genericError（v0.3.1 线上"扫码一片黑"的根因）。
# 必须用 `**`（跨包）重新 keep。
#
# 挂法见 android/app/build.gradle.kts：必须用 proguardFile(...) **追加**，
# 不能用 proguardFiles(...)（那是赋值，会整体覆盖 AGP/Flutter 注入的
# proguard-android-optimize.txt 与各插件自带的 consumer 规则）。
# ============================================================================

# ---- ML Kit 对外 API + 内部反射类 ----
-keep class com.google.mlkit.** { *; }
-keepclassmembers class com.google.mlkit.** { <fields>; <methods>; <init>(...); }

# ---- ML Kit 的 GMS 内部实现（barhopper / 条码识别内核）----
# 实测 mapping.txt：这 4 个包下上万个类曾被压成 a/b/c，是 genericError 的直接来源
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode_bundled.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_common.** { *; }

# ---- mobile_scanner 其余可选后端（视觉搜索 / 照片）----
-keep class com.google.android.libraries.barhopper.** { *; }
-keep class com.google.photos.vision.** { *; }

# ---- 反射 / 序列化 / 注解元数据：R8 默认会丢，丢了解析就炸 ----
-keepattributes Signature,InnerClasses,EnclosingMethod,*Annotation*,Exceptions

# ---- 兜底：不要为缺依赖的 MLKit 可选模块报错（否则 R8 直接构建失败）----
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**
-dontwarn com.google.android.libraries.barhopper.**
-dontwarn com.google.photos.vision.**

# ---- Google Play Core（deferred components / split install）----
# `-keep class io.flutter.**` 会把 Flutter engine 的
# PlayStoreDeferredComponentManager 一起保留下来，而这个类引用 Play Core 的
# splitinstall/tasks 类；本工程没接 deferred components，依赖不存在 →
# 不 dontwarn 的话 R8 会直接报 "Missing class" 构建失败（实测踩到）。
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**

# ---- CameraX：默认无反射，仅在"keep 后仍崩溃"的兜底方案里打开（见设计 A.4）----
# -keep class androidx.camera.** { *; }
# -dontwarn androidx.camera.**

# ---- Flutter embedding（插件注册走反射表）----
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
