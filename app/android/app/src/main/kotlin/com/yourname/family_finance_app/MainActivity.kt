package com.yourname.family_finance_app

import android.app.AlertDialog
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    /** 热启动深链：App 在后台时点小卡片，onNewIntent 拿到 URI 送到 Dart */
    private var linkSink: EventChannel.EventSink? = null
    private var pendingLink: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 国产 ROM（ColorOS/MIUI/EMUI…）的通知管控在系统层，App 只能引导用户去开
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "foreverrich/system")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "vendor" -> result.success("${android.os.Build.MANUFACTURER} ${android.os.Build.BRAND}".lowercase())
                    "openNotificationSettings" -> result.success(openNotificationSettings())
                    "openAutoStartSettings" -> result.success(openAutoStartSettings())
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "foreverrich/widget_link")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    linkSink = events
                    pendingLink?.let {
                        events?.success(it)
                        pendingLink = null
                    }
                }
                override fun onCancel(arguments: Any?) { linkSink = null }
            })
    }

    /** 打开本应用的通知设置页（各 ROM 通用） */
    private fun openNotificationSettings(): Boolean {
        return try {
            val i = Intent("android.settings.APP_NOTIFICATION_SETTINGS").apply {
                putExtra("android.provider.extra.APP_PACKAGE", packageName)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(i)
            true
        } catch (e: Exception) {
            try {
                startActivity(Intent("android.settings.APPLICATION_DETAILS_SETTINGS").apply {
                    data = android.net.Uri.parse("package:$packageName")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                })
                true
            } catch (_: Exception) { false }
        }
    }

    /** 打开自启动/后台管理页：按厂商尝试多个入口，全部失败返回 false 由 App 给文字指引 */
    private fun openAutoStartSettings(): Boolean {
        val candidates = listOf(
            // OPPO / ColorOS
            "com.coloros.safecenter" to "com.coloros.safecenter.permission.startup.StartupAppListActivity",
            "com.coloros.safecenter" to "com.coloros.safecenter.startupapp.StartupAppListActivity",
            "com.oppo.safe" to "com.oppo.safe.permission.startup.StartupAppListActivity",
            // vivo
            "com.vivo.permissionmanager" to "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
            // 小米
            "com.miui.securitycenter" to "com.miui.permcenter.autostart.AutoStartManagementActivity",
            // 华为
            "com.huawei.systemmanager" to "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
        )
        for ((pkg, cls) in candidates) {
            try {
                startActivity(Intent().apply {
                    setClassName(pkg, cls)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                })
                return true
            } catch (_: Exception) { }
        }
        return try {
            startActivity(Intent("android.settings.APPLICATION_DETAILS_SETTINGS").apply {
                data = android.net.Uri.parse("package:$packageName")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            })
            true
        } catch (_: Exception) { false }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val uri = intent.data?.toString() ?: return
        if (!uri.startsWith("foreverrich://")) return
        val sink = linkSink
        if (sink != null) sink.success(uri) else pendingLink = uri
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 按用户要求：允许截屏 / 录屏（不再设置 FLAG_SECURE）
        // root 环境提示保留：财务 App 在 root 设备上，本地加密数据可能被直接读取
        val isDebuggable =
            (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!isDebuggable) {
            if (isDeviceRooted()) {
                AlertDialog.Builder(this)
                    .setTitle("设备环境异常")
                    .setMessage(
                        "检测到当前设备已获取 root 权限。\n\n" +
                            "在 root 环境下，本地存储的登录凭证与账单数据可能被第三方程序读取。" +
                            "建议在未 root 的设备上使用本应用。"
                    )
                    .setPositiveButton("仍要继续") { d, _ -> d.dismiss() }
                    .setNegativeButton("退出") { _, _ -> finish() }
                    .setCancelable(false)
                    .show()
            }
        }
        intent?.data?.toString()?.takeIf { it.startsWith("foreverrich://") }?.let {
            pendingLink = it
        }
    }

    /** 常见 root 特征：su 可执行文件、Magisk 目录、测试签名的系统镜像 */
    private fun isDeviceRooted(): Boolean {
        val paths = arrayOf(
            "/system/app/Superuser.apk",
            "/sbin/su",
            "/system/bin/su",
            "/system/xbin/su",
            "/data/local/xbin/su",
            "/data/local/bin/su",
            "/system/sd/xbin/su",
            "/system/bin/failsafe/su",
            "/data/local/su",
            "/su/bin/su",
            "/system/xbin/daemonsu",
            "/sbin/.magisk",
            "/data/adb/magisk"
        )
        for (p in paths) {
            try {
                if (File(p).exists()) return true
            } catch (_: Throwable) {
            }
        }
        // 系统镜像带 test-keys 说明不是官方发布版
        return try {
            val tags = android.os.Build.TAGS
            tags != null && tags.contains("test-keys")
        } catch (_: Throwable) {
            false
        }
    }
}
