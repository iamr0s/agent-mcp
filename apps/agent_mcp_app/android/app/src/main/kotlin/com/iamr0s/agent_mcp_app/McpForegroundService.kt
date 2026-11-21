package com.iamr0s.agent_mcp_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager

class McpForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "agent_mcp_fgs_channel"
        const val NOTIFICATION_ID = 2026
        const val ACTION_SYNC = "com.iamr0s.agent_mcp_app.ACTION_SYNC"
        const val ACTION_STOP = "com.iamr0s.agent_mcp_app.ACTION_STOP"
        const val ACTION_RESTART = "com.iamr0s.agent_mcp_app.ACTION_RESTART"

        @Volatile
        var actionCallback: ((String) -> Unit)? = null
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
        acquireLocks()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_SYNC
        if (action == ACTION_STOP) {
            mainHandler.post { actionCallback?.invoke("stop") }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
            return START_NOT_STICKY
        }
        if (action == ACTION_RESTART) {
            mainHandler.post { actionCallback?.invoke("restart") }
        }

        val serverName = intent?.getStringExtra("serverName")?.takeIf { it.isNotBlank() } ?: "Android MCP"
        val port = intent?.getIntExtra("port", 8000) ?: 8000
        val lanIp = intent?.getStringExtra("lanIp")?.takeIf { it.isNotBlank() } ?: "127.0.0.1"
        val privBadge = intent?.getStringExtra("privilegeBadge")?.trim() ?: ""

        val notification = buildNotification(serverName, port, lanIp, privBadge)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val ch = NotificationChannel(
                CHANNEL_ID,
                "Agent MCP 服务常驻状态",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "保持本机 MCP 服务在后台与锁屏期间稳定监听"
                setShowBadge(false)
            }
            mgr.createNotificationChannel(ch)
        }
    }

    private fun buildNotification(
        serverName: String,
        port: Int,
        lanIp: String,
        privBadge: String
    ): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        val contentPi = PendingIntent.getActivity(this, 100, openIntent, piFlags)

        val stopIntent = Intent(this, McpForegroundService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPi = PendingIntent.getService(this, 101, stopIntent, piFlags)

        val restartIntent = Intent(this, McpForegroundService::class.java).apply {
            action = ACTION_RESTART
            putExtra("serverName", serverName)
            putExtra("port", port)
            putExtra("lanIp", lanIp)
            putExtra("privilegeBadge", privBadge)
        }
        val restartPi = PendingIntent.getService(this, 102, restartIntent, piFlags)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val tierSuffix = if (privBadge.isNotEmpty() && privBadge != "沙盒") " [$privBadge]" else ""
        builder
            .setSmallIcon(R.drawable.ic_stat_mcp)
            .setColor(0xFFD97757.toInt())
            .setContentTitle("$serverName · 运行中$tierSuffix")
            .setContentText("监听 :$port · http://$lanIp:$port/mcp")
            .setContentIntent(contentPi)
            .setOngoing(true)
            .setOnlyAlertOnce(true)

        val stopAction = Notification.Action.Builder(
            null,
            "停止服务",
            stopPi
        ).build()
        val restartAction = Notification.Action.Builder(
            null,
            "重启服务",
            restartPi
        ).build()
        builder.addAction(stopAction)
        builder.addAction(restartAction)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    private fun acquireLocks() {
        try {
            val pm = applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "AgentMcp::ServerWakeLock").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Throwable) {}
        try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                @Suppress("DEPRECATION")
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wm.createWifiLock(mode, "AgentMcp::ServerWifiLock").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Throwable) {}
    }

    private fun releaseLocks() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Throwable) {}
        wakeLock = null
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        } catch (_: Throwable) {}
        wifiLock = null
    }
}