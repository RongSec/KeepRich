package com.yourname.family_finance_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin

/**
 * 桌面小卡片渲染器（Android AppWidget —— 各厂商桌面统一机制）。
 *
 * 卡片：剩余可消费 / 当月已消费 + 范围切换（家庭/个人）+ 记账加号。
 *
 * 数据流：Flutter 侧 HomeWidgetService 把两个口径的数字写进
 * HomeWidgetPreferences；这里读同一份存储渲染 RemoteViews。
 * 范围切换在本地改 fw_scope 后重绘（不依赖 App 进程存活）。
 * key 必须与 app/lib/services/home_widget_service.dart 一字不差。
 */
class FinanceWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val ACTION_TOGGLE_SCOPE =
            "com.yourname.family_finance_app.widget.TOGGLE_SCOPE"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_TOGGLE_SCOPE) {
            // 范围切换：家庭 <-> 个人，本地改偏好后重绘，App 无需在跑
            val prefs = HomeWidgetPlugin.getData(context)
            val next =
                if (prefs.getString("fw_scope", "family") == "family") "personal" else "family"
            prefs.edit().putString("fw_scope", next).apply()
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(ComponentName(context, FinanceWidgetProvider::class.java))
            onUpdate(context, mgr, ids)
            return
        }
        super.onReceive(context, intent)
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val prefs = HomeWidgetPlugin.getData(context)
        val scope = prefs.getString("fw_scope", "family") ?: "family"
        val left = prefs.getString("fw_${scope}_left", "¥ --") ?: "¥ --"
        val spent = prefs.getString("fw_${scope}_spent", "¥ --") ?: "¥ --"

        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_finance).apply {
                setTextViewText(R.id.widget_consumable, "¥ $left")
                setTextViewText(R.id.widget_spent, "¥ $spent")
                setTextViewText(R.id.widget_scope, if (scope == "family") "家庭" else "个人")
                // 整卡点击 → 打开 App
                setOnClickPendingIntent(R.id.widget_root, launch(context, "foreverrich://overview"))
                // 加号 → 直达记账页
                setOnClickPendingIntent(R.id.widget_add, launch(context, "foreverrich://bookkeeping"))
                // 范围标签点击 → 切换口径
                setOnClickPendingIntent(R.id.widget_scope, toggleScope(context, appWidgetId))
            }
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }

    /** 打开 App 并带深链（Flutter 侧读 uri 决定落地页） */
    private fun launch(context: Context, uri: String): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            data = Uri.parse(uri)
            action = es.antonborri.home_widget.HomeWidgetLaunchIntent.HOME_WIDGET_LAUNCH_ACTION
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        return PendingIntent.getActivity(
            context, uri.hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    /** 范围切换广播（发给自己，onReceive 里处理） */
    private fun toggleScope(context: Context, appWidgetId: Int): PendingIntent {
        val intent = Intent(context, FinanceWidgetProvider::class.java).apply {
            action = ACTION_TOGGLE_SCOPE
        }
        return PendingIntent.getBroadcast(
            context, appWidgetId, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
