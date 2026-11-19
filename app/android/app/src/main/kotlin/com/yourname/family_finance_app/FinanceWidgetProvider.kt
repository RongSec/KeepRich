package com.yourname.family_finance_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin

/**
 * 桌面小卡片渲染器（Android AppWidget —— 各厂商桌面统一机制）。
 *
 * 数据流：Flutter 侧 HomeWidgetService 把总览数字写进 SharedPreferences，
 * 调 updateWidget 通知系统；这里被唤醒后读同一份存储渲染 RemoteViews。
 * 点击卡片 → 打开 App 总览页。
 *
 * key 必须与 app/lib/services/home_widget_service.dart 一字不差。
 */
class FinanceWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val data = HomeWidgetPlugin.getData(context)
        val wealth = data.getString("fw_total_wealth", "¥ --") ?: "¥ --"
        val consumable = data.getString("fw_month_consumable", "¥ --") ?: "¥ --"
        val remaining = data.getString("fw_remaining_budget", "¥ --") ?: "¥ --"
        val scope = data.getString("fw_scope", "家庭") ?: "家庭"

        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_finance).apply {
                setTextViewText(R.id.widget_wealth, "¥ $wealth")
                setTextViewText(R.id.widget_consumable, "¥ $consumable")
                setTextViewText(R.id.widget_remaining, "¥ $remaining")
                setTextViewText(R.id.widget_scope, scope)
                // 整卡点击 → 打开 App
                setOnClickPendingIntent(R.id.widget_root, launchApp(context))
            }
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }

    /** 打开 App 主入口（系统会走 Flutter 路由到当前页/总览） */
    private fun launchApp(context: Context): PendingIntent {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_LAUNCHER)
                setPackage(context.packageName)
            }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getActivity(context, 0, intent, flags)
    }
}
