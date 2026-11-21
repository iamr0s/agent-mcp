package com.iamr0s.agent_mcp_app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.WindowInsetsController
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface

class MainActivity : FlutterActivity() {
    private var androidChannel: MethodChannel? = null
    private var privilegeManager: PrivilegeManager? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdgeWindow()
        super.onCreate(savedInstanceState)
        enableEdgeToEdgeWindow()
    }

    override fun onResume() {
        super.onResume()
        privilegeManager?.ensureReadyIfNeededAsync { snap ->
            androidChannel?.invokeMethod("onPrivilegeChanged", snap)
        }
    }

    private fun enableEdgeToEdgeWindow() {
        val win = window ?: return
        win.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
        @Suppress("DEPRECATION")
        win.clearFlags(
            WindowManager.LayoutParams.FLAG_TRANSLUCENT_STATUS
                or WindowManager.LayoutParams.FLAG_TRANSLUCENT_NAVIGATION
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            win.attributes = win.attributes.apply {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            win.attributes = win.attributes.apply {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        win.statusBarColor = Color.TRANSPARENT
        win.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            win.isStatusBarContrastEnforced = false
            win.isNavigationBarContrastEnforced = false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            win.setDecorFitsSystemWindows(false)
        } else {
            @Suppress("DEPRECATION")
            win.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                )
        }
    }

    private fun applySystemBarIconBrightness(isDark: Boolean) {
        val win = window ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val ctrl = win.insetsController ?: return
            val mask = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
            ctrl.setSystemBarsAppearance(if (isDark) 0 else mask, mask)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            var vis = win.decorView.systemUiVisibility
            @Suppress("DEPRECATION")
            val flags = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
            vis = if (isDark) (vis and flags.inv()) else (vis or flags)
            @Suppress("DEPRECATION")
            win.decorView.systemUiVisibility = vis
        }
    }

    private fun ensureNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2026)
            }
        }
    }

    private fun classifyIpv4(ip: String, ifaceName: String): String {
        if (ip.startsWith("127.")) return "loopback"
        val lower = ifaceName.lowercase()
        if (lower.contains("tailscale") || lower.startsWith("tun") || lower.startsWith("wg") || ip.startsWith("100.")) {
            return "vpn"
        }
        return "lan"
    }

    private fun queryNetworkEntries(): List<Map<String, String>> {
        val out = mutableListOf<Map<String, String>>()
        val seen = HashSet<String>()
        out.add(mapOf("ip" to "127.0.0.1", "iface" to "lo", "kind" to "loopback"))
        seen.add("127.0.0.1")
        try {
            val ifaces = NetworkInterface.getNetworkInterfaces() ?: return out
            for (nif in ifaces) {
                if (!nif.isUp || nif.isLoopback) continue
                val ifName = nif.name ?: ""
                for (addr in nif.inetAddresses) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        val ip = addr.hostAddress ?: continue
                        if (ip.isNotBlank() && seen.add(ip)) {
                            out.add(
                                mapOf(
                                    "ip" to ip,
                                    "iface" to ifName,
                                    "kind" to classifyIpv4(ip, ifName)
                                )
                            )
                        }
                    }
                }
            }
        } catch (_: Throwable) {}
        return out
    }

    private fun queryLanIpv4s(): List<String> {
        return queryNetworkEntries()
            .mapNotNull { it["ip"] }
            .filter { it != "127.0.0.1" }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "agent_mcp/android")
        androidChannel = ch

        privilegeManager?.destroy()
        val pm = PrivilegeManager(applicationContext) { stateMap ->
            runOnUiThread {
                androidChannel?.invokeMethod("onPrivilegeChanged", stateMap)
            }
        }
        privilegeManager = pm

        McpForegroundService.actionCallback = { act ->
            runOnUiThread {
                androidChannel?.invokeMethod("onNotificationAction", act)
            }
        }

        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "getPaths" -> {
                    val intDir = filesDir.absolutePath
                    val extDir = getExternalFilesDir(null)?.absolutePath ?: intDir
                    result.success(
                        mapOf(
                            "filesDir" to intDir,
                            "externalFilesDir" to extDir,
                            "lanIps" to queryLanIpv4s(),
                            "networkInterfaces" to queryNetworkEntries(),
                            "privilege" to pm.buildStatusMap()
                        )
                    )
                }
                "getNetworkInterfaces" -> {
                    result.success(queryNetworkEntries())
                }
                "getPrivilegeStatus" -> {
                    result.success(pm.buildStatusMap())
                }
                "applyPrivilegeConfig" -> {
                    val args = call.arguments as? Map<*, *>
                    val mode = (args?.get("mode") as? String) ?: "none"
                    val mountMaster = (args?.get("mountMaster") as? Boolean) ?: true
                    val interactive = (args?.get("interactive") as? Boolean) ?: false
                    pm.applyConfigAsync(mode, mountMaster, interactive) { snap ->
                        result.success(snap)
                    }
                }
                "ensurePrivilegeReady" -> {
                    pm.ensureReadyIfNeededAsync { snap ->
                        result.success(snap)
                    }
                }
                "requestShizukuPermission" -> {
                    pm.requestShizukuPermissionAsync { snap ->
                        result.success(snap)
                    }
                }
                "openPrivilegeManagerApp" -> {
                    val target = (call.arguments as? String) ?: "shizuku"
                    val ok = pm.openManagerApp(target)
                    result.success(ok)
                }
                "syncForegroundService" -> {
                    val args = call.arguments as? Map<*, *>
                    val running = (args?.get("running") as? Boolean) ?: false
                    if (running) {
                        ensureNotificationPermissionIfNeeded()
                        val serverName = (args?.get("serverName") as? String) ?: "Android MCP"
                        val port = (args?.get("port") as? Number)?.toInt() ?: 8000
                        val lanIp = (args?.get("lanIp") as? String) ?: "127.0.0.1"
                        val privBadge = (args?.get("privilegeBadge") as? String) ?: ""
                        val svcIntent = Intent(this, McpForegroundService::class.java).apply {
                            action = McpForegroundService.ACTION_SYNC
                            putExtra("serverName", serverName)
                            putExtra("port", port)
                            putExtra("lanIp", lanIp)
                            putExtra("privilegeBadge", privBadge)
                        }
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(svcIntent)
                            } else {
                                startService(svcIntent)
                            }
                        } catch (_: Throwable) {}
                    } else {
                        try {
                            stopService(Intent(this, McpForegroundService::class.java))
                        } catch (_: Throwable) {}
                    }
                    result.success(null)
                }
                "setSystemBarsDark" -> {
                    val isDark = (call.arguments as? Boolean) ?: false
                    applySystemBarIconBrightness(isDark)
                    result.success(null)
                }
                "openExternalUrl" -> {
                    val url = (call.arguments as? String) ?: ""
                    if (url.isNotBlank()) {
                        try {
                            val viewIntent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(viewIntent)
                        } catch (_: Throwable) {}
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        if (McpForegroundService.actionCallback != null) {
            McpForegroundService.actionCallback = null
        }
        privilegeManager?.destroy()
        privilegeManager = null
        androidChannel?.setMethodCallHandler(null)
        androidChannel = null
        super.onDestroy()
    }
}