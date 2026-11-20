package com.example.ros_tester

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.BitmapFactory
import java.io.File
import android.net.Uri
import android.os.Build
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Home screen widget: the robot's state as the app last wrote it (connected or not, what is running,
 * battery) and, while connected, Run (the routine run last) and Stop. Both open the app, which acts at
 * once: the app holds the robot connection, the widget never does (lib/robot_widget.dart).
 */
class RobotWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val title = widgetData.getString("title", null) ?: "Mobile ROS"
        val text = widgetData.getString("text", null) ?: "Not connected. Tap to open."
        val connected = widgetData.getBoolean("connected", false)
        val battery = widgetData.getString("battery", null) ?: ""
        val routineId = widgetData.getString("routine_id", null) ?: ""
        val routineName = widgetData.getString("routine_name", null) ?: ""
        val running = widgetData.getBoolean("running", false)
        val canConnect = widgetData.getBoolean("can_connect", false)
        val detail = widgetData.getString("detail", null) ?: ""
        val updated = widgetData.getString("updated", null) ?: ""
        val mapPath = widgetData.getString("map_path", null) ?: ""
        val where = widgetData.getString("where", null) ?: ""
        val problems = widgetData.getInt("problems", -1)
        // Words in the app's language, written by the app (English until it has run once).
        fun label(key: String, english: String) =
            widgetData.getString(key, null)?.takeIf { it.isNotEmpty() } ?: english
        // The app's picture of the map around the robot (only while connected).
        val map = if (connected && mapPath.isNotEmpty() && File(mapPath).exists())
            BitmapFactory.decodeFile(mapPath) else null
        fun build(layout: Int, full: Boolean) = RemoteViews(context.packageName, layout).apply {
            setTextViewText(R.id.widget_title, title)
            setTextViewText(R.id.widget_text, text)
            if (full) {
                setTextViewText(R.id.widget_detail, detail)
                // When the app last wrote this: an old time tells the person the state may be stale.
                setTextViewText(R.id.widget_time, updated)
                if (map != null) setImageViewBitmap(R.id.widget_map, map)
                setViewVisibility(R.id.widget_map, if (map != null) View.VISIBLE else View.GONE)
                // One glance line (a 4 x 2 widget has room for one, measured on the emulator: a second
                // line was squeezed to nothing): new warnings first, else where it is, else "No problems".
                val (glance, color) = when {
                    problems > 0 -> label("label_warnings",
                        "\u26A0  $problems new warning" + (if (problems == 1) "" else "s")) to 0xFFFFB74D.toInt()
                    where.isNotEmpty() -> "\uD83D\uDCCD  $where" to 0xFFCFDAE3.toInt()
                    problems == 0 -> "\u2713  ${label("label_no_problems", "No problems")}" to 0xFF4FD1A5.toInt()
                    else -> "" to 0
                }
                setTextViewText(R.id.widget_where, glance)
                if (glance.isNotEmpty()) setTextColor(R.id.widget_where, color)
                setViewVisibility(R.id.widget_where, if (connected && glance.isNotEmpty()) View.VISIBLE else View.GONE)
            }
            setImageViewResource(R.id.widget_dot,
                if (connected) R.drawable.widget_dot_on else R.drawable.widget_dot_off)
            setTextViewText(R.id.widget_battery, battery)
            setViewVisibility(R.id.widget_battery, if (battery.isNotEmpty()) View.VISIBLE else View.GONE)
            setTextViewText(R.id.widget_stop, label("label_stop", "Stop"))
            setOnClickPendingIntent(R.id.widget_root,
                HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse("mobileros://open")))
            setOnClickPendingIntent(R.id.widget_stop,
                HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse("mobileros://stop")))
            if (full) {
                // Connected: Run (the routine run last) and Stop; while a routine runs only Stop.
                // Not connected: Connect, which opens the app and connects to the robot used last.
                setViewVisibility(R.id.widget_buttons, if (connected || canConnect) View.VISIBLE else View.GONE)
                setViewVisibility(R.id.widget_stop, if (connected && !running) View.VISIBLE else View.GONE)
                setViewVisibility(R.id.widget_stop_wide, if (connected && running) View.VISIBLE else View.GONE)
                setTextViewText(R.id.widget_stop_wide, label("label_stop_routine", "■  Stop routine"))
                setOnClickPendingIntent(R.id.widget_stop_wide,
                    HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse("mobileros://stop")))
                if (connected) {
                    setViewVisibility(R.id.widget_run,
                        if (routineId.isNotEmpty() && !running) View.VISIBLE else View.GONE)
                    setTextViewText(R.id.widget_run, "▶  $routineName")
                    // A distinct URI per routine, so Android keeps a separate pending intent for it.
                    setOnClickPendingIntent(R.id.widget_run, HomeWidgetLaunchIntent.getActivity(context,
                        MainActivity::class.java, Uri.parse("mobileros://run?routine=" + Uri.encode(routineId))))
                } else {
                    setViewVisibility(R.id.widget_run, View.VISIBLE)
                    setTextViewText(R.id.widget_run, label("label_connect", "Connect"))
                    setOnClickPendingIntent(R.id.widget_run, HomeWidgetLaunchIntent.getActivity(context,
                        MainActivity::class.java, Uri.parse("mobileros://connect")))
                }
            } else {
                setViewVisibility(R.id.widget_stop, if (connected) View.VISIBLE else View.GONE)
            }
        }
        for (id in appWidgetIds) {
            // Android 12+: the launcher picks the layout that fits the size the person gave the widget.
            val views = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                RemoteViews(mapOf(
                    SizeF(180f, 40f) to build(R.layout.robot_widget_small, false),
                    SizeF(180f, 100f) to build(R.layout.robot_widget, true),
                ))
            } else {
                val h = appWidgetManager.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT)
                if (h in 1..99) build(R.layout.robot_widget_small, false) else build(R.layout.robot_widget, true)
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
