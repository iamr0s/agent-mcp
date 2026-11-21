package com.iamr0s.agent_mcp_app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.system.Os
import org.json.JSONObject
import rikka.shizuku.Shizuku
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.nio.charset.StandardCharsets
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class PrivilegeManager(
    private val context: Context,
    private val onStateChanged: (Map<String, Any?>) -> Unit
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val appUid: Int = try { Os.getuid() } catch (_: Throwable) { -1 }

    @Volatile var requestedMode: String = "none"
        private set
    @Volatile var mountMaster: Boolean = true
        private set

    @Volatile private var bridgeReady: Boolean = false
    @Volatile private var activeBackend: String = "none"
    @Volatile private var bridgePort: Int = 0
    @Volatile private var bridgeToken: String = ""
    @Volatile private var effectiveUid: Int = appUid
    @Volatile private var effectiveUser: String = "u0_app"
    @Volatile private var lastError: String = ""

    @Volatile private var shizukuService: IMcpPrivilegedService? = null
    @Volatile private var shizukuBound: Boolean = false
    @Volatile private var activeConnection: ServiceConnection? = null
    private var activeServiceArgs: Shizuku.UserServiceArgs? = null

    @Volatile private var rootProc: Process? = null

    private var pendingPermCallback: ((Boolean) -> Unit)? = null
    private val permReqCode = 202609

    private val binderReceivedListener = Shizuku.OnBinderReceivedListener {
        if (requestedMode == "shizuku" && !bridgeReady) {
            worker.execute {
                connectShizukuInternal()
                notifyChanged()
            }
        } else {
            notifyChanged()
        }
    }

    private val binderDeadListener = Shizuku.OnBinderDeadListener {
        shizukuService = null
        shizukuBound = false
        if (requestedMode == "shizuku") {
            resetToSandboxFallback("Shizuku 服务已停止，重新激活后将自动恢复连接")
        }
        notifyChanged()
    }

    private val permResultListener =
        Shizuku.OnRequestPermissionResultListener { requestCode, grantResult ->
            if (requestCode == permReqCode) {
                val granted = grantResult == PackageManager.PERMISSION_GRANTED
                val cb = pendingPermCallback
                pendingPermCallback = null
                if (granted && requestedMode == "shizuku") {
                    worker.execute {
                        connectShizukuInternal()
                        notifyChanged()
                        mainHandler.post { cb?.invoke(true) }
                    }
                } else {
                    if (!granted && requestedMode == "shizuku") {
                        lastError = "Shizuku 授权被拒绝，请在弹窗或 Shizuku 应用内允许 Agent MCP"
                    }
                    notifyChanged()
                    mainHandler.post { cb?.invoke(granted) }
                }
            }
        }

    init {
        try {
            Shizuku.addBinderReceivedListenerSticky(binderReceivedListener)
            Shizuku.addBinderDeadListener(binderDeadListener)
            Shizuku.addRequestPermissionResultListener(permResultListener)
        } catch (_: Throwable) {}
    }

    fun destroy() {
        try {
            Shizuku.removeBinderReceivedListener(binderReceivedListener)
            Shizuku.removeBinderDeadListener(binderDeadListener)
            Shizuku.removeRequestPermissionResultListener(permResultListener)
        } catch (_: Throwable) {}
        teardownActiveBridge()
        worker.shutdownNow()
    }

    private fun isPackageInstalled(pkg: String): Boolean {
        return try {
            context.packageManager.getPackageInfo(pkg, 0)
            true
        } catch (_: Throwable) {
            false
        }
    }

    fun detectRootManagers(): List<Map<String, String>> {
        val candidates = listOf(
            "me.weishu.kernelsu" to "KernelSU",
            "com.rifsxd.ksunext" to "KernelSU Next",
            "me.bmax.apatch" to "APatch",
            "com.topjohnwu.magisk" to "Magisk",
            "io.github.vvb2060.magisk" to "Magisk Alpha"
        )
        val out = mutableListOf<Map<String, String>>()
        for ((pkg, name) in candidates) {
            if (isPackageInstalled(pkg)) {
                out.add(mapOf("package" to pkg, "name" to name))
            }
        }
        return out
    }

    private fun hasVisibleSuBinary(): Boolean {
        val paths = listOf(
            "/system/bin/su",
            "/system/xbin/su",
            "/sbin/su",
            "/vendor/bin/su",
            "/data/adb/ksu/bin/ksud",
            "/data/adb/ap/bin/apd"
        )
        return paths.any {
            try { File(it).exists() } catch (_: Throwable) { false }
        }
    }

    fun buildStatusMap(): Map<String, Any?> {
        val shizukuInstalled = isPackageInstalled("moe.shizuku.privileged.api")
        val shizukuRunning = try { Shizuku.pingBinder() } catch (_: Throwable) { false }
        val shizukuPreV11 = if (shizukuRunning) {
            try { Shizuku.isPreV11() } catch (_: Throwable) { false }
        } else false
        val shizukuAuthorized = if (shizukuRunning && !shizukuPreV11) {
            try {
                Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
            } catch (_: Throwable) {
                false
            }
        } else false
        val shizukuUid = if (shizukuRunning && shizukuAuthorized) {
            try { Shizuku.getUid() } catch (_: Throwable) { -1 }
        } else -1
        val shizukuVersion = if (shizukuRunning) {
            try { Shizuku.getVersion() } catch (_: Throwable) { -1 }
        } else -1

        val managers = detectRootManagers()
        val suVisible = hasVisibleSuBinary()

        val shizukuTierLabel = when (shizukuUid) {
            0 -> "Shizuku · Root (UID 0)"
            2000 -> "Shizuku · ADB (UID 2000)"
            else -> if (shizukuRunning) "Shizuku 已运行" else "Shizuku 未运行"
        }

        val effectiveLabel = when {
            bridgeReady && activeBackend == "shizuku" -> {
                if (effectiveUid == 0) "Shizuku · Root (UID 0)"
                else "Shizuku · ADB (UID $effectiveUid)"
            }
            bridgeReady && activeBackend == "root" -> {
                if (mountMaster) "Root SU · 全局命名空间 (UID 0)"
                else "Root SU (UID 0)"
            }
            else -> "普通沙盒 (UID $appUid)"
        }

        val shortBadge = when {
            bridgeReady && activeBackend == "shizuku" -> {
                if (effectiveUid == 0) "Shizuku Root" else "Shizuku ADB"
            }
            bridgeReady && activeBackend == "root" -> "Root SU"
            else -> "沙盒"
        }

        return mapOf(
            "supported" to true,
            "requested_mode" to requestedMode,
            "active_mode" to if (bridgeReady) activeBackend else "none",
            "mount_master" to mountMaster,
            "bridge_ready" to bridgeReady,
            "bridge_port" to if (bridgeReady) bridgePort else 0,
            "bridge_token" to if (bridgeReady) bridgeToken else "",
            "app_uid" to appUid,
            "effective_uid" to if (bridgeReady) effectiveUid else appUid,
            "effective_user" to if (bridgeReady) effectiveUser else "u0_app",
            "effective_label" to effectiveLabel,
            "short_badge" to shortBadge,
            "error" to lastError,
            "shizuku_installed" to (shizukuInstalled || shizukuRunning),
            "shizuku_running" to shizukuRunning,
            "shizuku_authorized" to shizukuAuthorized,
            "shizuku_uid" to shizukuUid,
            "shizuku_version" to shizukuVersion,
            "shizuku_tier_label" to shizukuTierLabel,
            "root_managers" to managers,
            "su_visible" to (suVisible || managers.isNotEmpty())
        )
    }

    private fun notifyChanged() {
        val snap = buildStatusMap()
        mainHandler.post {
            onStateChanged(snap)
        }
    }

    private fun resetToSandboxFallback(err: String = "") {
        bridgeReady = false
        activeBackend = "none"
        bridgePort = 0
        bridgeToken = ""
        effectiveUid = appUid
        effectiveUser = "u0_app"
        lastError = err
    }

    private fun teardownActiveBridge() {
        // Stop Shizuku UserService if bound
        val args = activeServiceArgs
        val conn = activeConnection
        activeServiceArgs = null
        activeConnection = null
        shizukuService = null
        shizukuBound = false
        if (args != null && conn != null) {
            mainHandler.post {
                try {
                    Shizuku.unbindUserService(args, conn, true)
                } catch (_: Throwable) {}
            }
        }

        // Stop Root daemon process if running
        val rp = rootProc
        rootProc = null
        if (rp != null) {
            try { rp.outputStream.close() } catch (_: Throwable) {}
            try { rp.destroyForcibly() } catch (_: Throwable) {
                try { rp.destroy() } catch (_: Throwable) {}
            }
        }
        resetToSandboxFallback("")
    }

    fun applyConfigAsync(
        mode: String,
        useMountMaster: Boolean,
        interactive: Boolean,
        onDone: (Map<String, Any?>) -> Unit
    ) {
        val normMode = when (mode.trim().lowercase()) {
            "shizuku" -> "shizuku"
            "root" -> "root"
            else -> "none"
        }
        worker.execute {
            val sameConfig = (normMode == requestedMode && useMountMaster == mountMaster)
            if (sameConfig && normMode != "none" && bridgeReady && activeBackend == normMode) {
                val st = buildStatusMap()
                mainHandler.post { onDone(st) }
                return@execute
            }

            teardownActiveBridge()
            requestedMode = normMode
            mountMaster = useMountMaster

            when (normMode) {
                "none" -> {
                    resetToSandboxFallback("")
                }
                "shizuku" -> {
                    connectShizukuInternal()
                }
                "root" -> {
                    connectRootInternal(interactive = interactive)
                }
            }
            val snap = buildStatusMap()
            mainHandler.post {
                onStateChanged(snap)
                onDone(snap)
            }
        }
    }

    fun ensureReadyIfNeededAsync(onDone: (Map<String, Any?>) -> Unit) {
        worker.execute {
            if (requestedMode != "none" && !bridgeReady) {
                if (requestedMode == "shizuku") {
                    connectShizukuInternal()
                } else if (requestedMode == "root") {
                    connectRootInternal(interactive = false)
                }
                val snap = buildStatusMap()
                mainHandler.post {
                    onStateChanged(snap)
                    onDone(snap)
                }
            } else {
                val snap = buildStatusMap()
                mainHandler.post { onDone(snap) }
            }
        }
    }

    fun requestShizukuPermissionAsync(onDone: (Map<String, Any?>) -> Unit) {
        val running = try { Shizuku.pingBinder() } catch (_: Throwable) { false }
        if (!running) {
            lastError = "Shizuku 服务未运行，请先打开 Shizuku 完成无线调试或 Root 激活"
            val snap = buildStatusMap()
            onStateChanged(snap)
            onDone(snap)
            return
        }
        if (try { Shizuku.isPreV11() } catch (_: Throwable) { false }) {
            lastError = "当前 Shizuku 版本过旧 (< v11)，请升级最新 Shizuku"
            val snap = buildStatusMap()
            onStateChanged(snap)
            onDone(snap)
            return
        }
        if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
            applyConfigAsync("shizuku", mountMaster, interactive = true, onDone = onDone)
            return
        }

        pendingPermCallback = { _ ->
            onDone(buildStatusMap())
        }
        try {
            Shizuku.requestPermission(permReqCode)
        } catch (t: Throwable) {
            pendingPermCallback = null
            lastError = "唤起 Shizuku 授权失败: ${t.message}"
            val snap = buildStatusMap()
            onStateChanged(snap)
            onDone(snap)
        }
    }

    fun openManagerApp(targetPkgOrAlias: String): Boolean {
        val pkg = when (targetPkgOrAlias.trim()) {
            "", "shizuku" -> "moe.shizuku.privileged.api"
            "kernelsu" -> "me.weishu.kernelsu"
            "apatch" -> "me.bmax.apatch"
            "magisk" -> "com.topjohnwu.magisk"
            else -> targetPkgOrAlias.trim()
        }
        return try {
            val launch = context.packageManager.getLaunchIntentForPackage(pkg) ?: return false
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(launch)
            true
        } catch (_: Throwable) {
            false
        }
    }

    private fun connectShizukuInternal() {
        val running = try { Shizuku.pingBinder() } catch (_: Throwable) { false }
        if (!running) {
            val installed = isPackageInstalled("moe.shizuku.privileged.api")
            resetToSandboxFallback(
                if (installed) "Shizuku 尚未激活运行，请打开 Shizuku 启动服务后自动重连"
                else "未检测到 Shizuku，请先安装并激活 Shizuku (或 Sui)"
            )
            return
        }
        if (try { Shizuku.isPreV11() } catch (_: Throwable) { false }) {
            resetToSandboxFallback("Shizuku 版本过旧，请升级至 v13+")
            return
        }
        val granted = try {
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        } catch (_: Throwable) {
            false
        }
        if (!granted) {
            resetToSandboxFallback("尚未授予 Shizuku 权限，请点击「授权 Shizuku」允许访问")
            return
        }

        val latch = CountDownLatch(1)
        var connectedBinder: IBinder? = null

        val svcArgs = Shizuku.UserServiceArgs(
            ComponentName(context.packageName, McpShizukuUserService::class.java.name)
        )
            .daemon(false)
            .processNameSuffix("mcp_shizuku")
            .debuggable(false)
            .version(200)

        val conn = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                if (service != null && service.pingBinder()) {
                    connectedBinder = service
                }
                latch.countDown()
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                shizukuService = null
                shizukuBound = false
                if (requestedMode == "shizuku") {
                    resetToSandboxFallback("Shizuku 特权桥接已断开")
                    notifyChanged()
                }
            }
        }

        activeServiceArgs = svcArgs
        activeConnection = conn

        mainHandler.post {
            try {
                Shizuku.bindUserService(svcArgs, conn)
            } catch (t: Throwable) {
                lastError = "绑定 Shizuku UserService 失败: ${t.message}"
                latch.countDown()
            }
        }

        val awaited = latch.await(8, TimeUnit.SECONDS)
        val binder = connectedBinder
        if (!awaited || binder == null) {
            resetToSandboxFallback(
                lastError.ifEmpty { "连接 Shizuku UserService 超时，请确认 Shizuku 正常运行后点击重连" }
            )
            return
        }

        try {
            val stub = IMcpPrivilegedService.Stub.asInterface(binder)
            val infoStr = stub.bridgeInfoJson
            val info = JSONObject(infoStr)
            shizukuService = stub
            shizukuBound = true
            bridgePort = info.getInt("port")
            bridgeToken = info.getString("token")
            effectiveUid = info.optInt("uid", 2000)
            effectiveUser = info.optString("user", if (effectiveUid == 0) "root" else "shell")
            activeBackend = "shizuku"
            bridgeReady = true
            lastError = ""
        } catch (t: Throwable) {
            resetToSandboxFallback("解析 Shizuku 桥接信息失败: ${t.message}")
        }
    }

    private fun connectRootInternal(interactive: Boolean) {
        val apkPath = context.applicationInfo.sourceDir
        val timeoutSec = if (interactive) 15L else 5L

        val attempts = if (mountMaster) {
            listOf(listOf("su", "--mount-master"), listOf("su"))
        } else {
            listOf(listOf("su"))
        }

        var lastFailure = ""
        for (suCmd in attempts) {
            val res = trySpawnRootDaemon(suCmd, apkPath, timeoutSec)
            if (res.first) {
                return
            }
            lastFailure = res.second
            // If su wasn't found or permission denied, no need to retry without --mount-master
            if (lastFailure.contains("Permission denied", ignoreCase = true) ||
                lastFailure.contains("No such file", ignoreCase = true) ||
                lastFailure.contains("Cannot run program", ignoreCase = true)
            ) {
                break
            }
        }

        val managers = detectRootManagers()
        val hint = if (managers.isNotEmpty()) {
            val mgrNames = managers.joinToString(" / ") { it["name"] ?: "Root 管理器" }
            "尚未获得 Root 授权：请在 $mgrNames 中为「Agent MCP」开启超级用户权限后点击重连"
        } else if (lastFailure.isNotBlank()) {
            "无法启动 Root SU 守护进程: $lastFailure"
        } else {
            "未检测到可用的 su 授权，请确认设备已获取 Root 权限"
        }
        resetToSandboxFallback(hint)
    }

    private fun trySpawnRootDaemon(
        suBaseArgs: List<String>,
        apkPath: String,
        timeoutSec: Long
    ): Pair<Boolean, String> {
        val escapedApk = apkPath.replace("'", "'\\''")
        val launchScript =
            "export CLASSPATH='$escapedApk'; exec /system/bin/app_process /system/bin --nice-name=agent_mcp_su com.iamr0s.agent_mcp_app.McpPrivilegedDaemonMain"
        val fullCmd = ArrayList<String>(suBaseArgs.size + 2).apply {
            addAll(suBaseArgs)
            add("-c")
            add(launchScript)
        }

        val proc: Process = try {
            ProcessBuilder(fullCmd)
                .redirectErrorStream(true)
                .start()
        } catch (t: Throwable) {
            return false to (t.message ?: t.toString())
        }

        val latch = CountDownLatch(1)
        var readyJson: JSONObject? = null
        val errLines = mutableListOf<String>()

        Thread({
            try {
                val reader = BufferedReader(InputStreamReader(proc.inputStream, StandardCharsets.UTF_8))
                while (true) {
                    val line = reader.readLine() ?: break
                    val idx = line.indexOf("MCP_PRIV_READY:")
                    if (idx >= 0) {
                        val payload = line.substring(idx + "MCP_PRIV_READY:".length).trim()
                        readyJson = JSONObject(payload)
                        latch.countDown()
                    } else if (readyJson == null && line.isNotBlank()) {
                        synchronized(errLines) {
                            if (errLines.size < 6) errLines.add(line.trim())
                        }
                    }
                }
            } catch (_: Throwable) {
            } finally {
                latch.countDown()
                if (rootProc === proc) {
                    rootProc = null
                    if (requestedMode == "root") {
                        resetToSandboxFallback("Root SU 守护进程已退出")
                        notifyChanged()
                    }
                }
            }
        }, "mcp-root-handshake").apply {
            isDaemon = true
            start()
        }

        val ok = latch.await(timeoutSec, TimeUnit.SECONDS) && readyJson != null
        val info = readyJson
        if (ok && info != null) {
            rootProc = proc
            bridgePort = info.getInt("port")
            bridgeToken = info.getString("token")
            effectiveUid = info.optInt("uid", 0)
            effectiveUser = info.optString("user", "root")
            activeBackend = "root"
            bridgeReady = true
            lastError = ""
            return true to ""
        }

        try { proc.outputStream.close() } catch (_: Throwable) {}
        try { proc.destroyForcibly() } catch (_: Throwable) {}
        val detail = synchronized(errLines) { errLines.joinToString("; ") }
        return false to detail
    }
}