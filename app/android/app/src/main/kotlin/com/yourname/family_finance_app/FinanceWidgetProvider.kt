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
 * 桌面小卡片渲染基类（Android AppWidget —— 各厂商桌面统一机制）。
 *
 * 两种尺寸：4x2 中卡（剩余可消费 + 当月已消费）与 2x2 小卡（只留剩余可消费），
 * 由子类提供布局；字段 id 约定一致（widget_root / widget_scope /
 * widget_consumable / widget_add），公共逻辑集中在这里。
 *
 * 口径（家庭/个人）在卡片上点范围片切换：本地改 fw_scope 后重绘，
 * 不依赖 App 进程存活。key 必须与 home_widget_service.dart 一字不差。
 */
abstract class BaseFinanceWidgetProvider : AppWidgetProvider() {

    /** 子类布局（4x2 或 2x2） */
    protected abstract val layoutId: Int

    /** 中卡才有「当月已消费」列 */
    protected open val spentViewId: Int? = null

    companion object {
        private const val ACTION_TOGGLE_SCOPE =
            "com.yourname.family_finance_app.widget.TOGGLE_SCOPE"
        private const val ACTION_TOGGLE_MASK =
            "com.yourname.family_finance_app.widget.TOGGLE_MASK"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val prefs = HomeWidgetPlugin.getData(context)
        when (intent.action) {
            ACTION_TOGGLE_SCOPE -> {
                val next =
                    if (prefs.getString("fw_scope", "family") == "family") "personal" else "family"
                prefs.edit().putString("fw_scope", next).apply()
            }
            ACTION_TOGGLE_MASK -> {
                // 眼睛：遮蔽 / 显示金额（本地状态，App 无需在跑）
                val masked = prefs.getBoolean("fw_mask", false)
                prefs.edit().putBoolean("fw_mask", !masked).apply()
            }
            else -> {
                super.onReceive(context, intent)
                return
            }
        }
        val mgr = AppWidgetManager.getInstance(context)
        val ids = mgr.getAppWidgetIds(ComponentName(context, javaClass))
        onUpdate(context, mgr, ids)
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val prefs = HomeWidgetPlugin.getData(context)
        var scope = prefs.getString("fw_scope", "family") ?: "family"
        // 偏好口径还没同步过数据（如家庭未建）时兜底到另一口径，别显示 "--"
        if (prefs.getString("fw_${scope}_left", null) == null) {
            val other = if (scope == "family") "personal" else "family"
            if (prefs.getString("fw_${other}_left", null) != null) scope = other
        }
        val masked = prefs.getBoolean("fw_mask", false)
        val mask = "¥ ••••••"
        val left = if (masked) mask else "¥ " + (prefs.getString("fw_${scope}_left", "--") ?: "--")
        val spent = if (masked) mask else "¥ " + (prefs.getString("fw_${scope}_spent", "--") ?: "--")

        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, layoutId).apply {
                setTextViewText(R.id.widget_consumable, left)
                spentViewId?.let { setTextViewText(it, spent) }
                setTextViewText(R.id.widget_scope, if (scope == "family") "家庭" else "个人")
                setOnClickPendingIntent(R.id.widget_root, launch(context, "foreverrich://overview"))
                setOnClickPendingIntent(
                    R.id.widget_add,
                    launch(context, "foreverrich://new")
                )
                setOnClickPendingIntent(
                    R.id.widget_scope,
                    action(context, appWidgetId, ACTION_TOGGLE_SCOPE)
                )
                // 眼睛：遮蔽 / 显示金额
                setOnClickPendingIntent(
                    R.id.widget_eye,
                    action(context, appWidgetId + 10000, ACTION_TOGGLE_MASK)
                )
            }
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }

    /** 打开 App 并带深链（Flutter 侧读 uri 决定落地页 / 是否直接弹记账表单） */
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

    /** 卡片内小动作广播（范围切换 / 金额遮蔽），发给自己由 onReceive 处理 */
    private fun action(context: Context, requestCode: Int, action: String): PendingIntent {
        val intent = Intent(context, javaClass).apply { this.action = action }
        return PendingIntent.getBroadcast(
            context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}

/** 4x2 中卡：剩余可消费 + 当月已消费 + 范围切换 + 记账加号 */
class FinanceWidgetProvider : BaseFinanceWidgetProvider() {
    override val layoutId: Int get() = R.layout.widget_finance
    override val spentViewId: Int? get() = R.id.widget_spent
}

/** 2x2 小卡：剩余可消费 + 当月已消费 + 范围切换 + 记账加号（紧凑排布） */
class FinanceWidgetProviderSmall : BaseFinanceWidgetProvider() {
    override val layoutId: Int get() = R.layout.widget_finance_small
    override val spentViewId: Int? get() = R.id.widget_spent
}
