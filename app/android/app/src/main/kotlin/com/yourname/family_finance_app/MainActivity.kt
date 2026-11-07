package com.yourname.family_finance_app

import android.app.AlertDialog
import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 截图 / 录屏防护：财务数据不允许被截取
        // （系统最近任务预览、第三方截屏、录屏都会得到黑屏）
        // 仅正式包启用 —— debug 包要能截屏调试
        val isDebuggable =
            (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!isDebuggable) {
            window.setFlags(
                WindowManager.LayoutParams.FLAG_SECURE,
                WindowManager.LayoutParams.FLAG_SECURE
            )
            // root 环境提示：财务 App 在 root 设备上，本地加密数据可能被直接读取
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
