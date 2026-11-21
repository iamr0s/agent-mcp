package com.iamr0s.agent_mcp_app

import android.system.Os
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class PrivilegedLoopbackServer {
    private class ManagedChild(
        val id: String,
        val command: String,
        val cwd: String,
        val proc: Process,
        val pid: Int,
        val startedAtMs: Long,
    ) {
        val lock = Object()
        val lines = ArrayDeque<String>(5000)
        @Volatile var exitCode: Int? = null
        @Volatile var endedAtMs: Long? = null
        @Volatile var stdoutDone = false
        @Volatile var stderrDone = false

        fun appendLine(line: String) {
            synchronized(lock) {
                if (lines.size >= 5000) {
                    lines.removeFirst()
                }
                lines.addLast(line)
            }
        }

        fun snapshotLines(tail: Int? = null): List<String> {
            synchronized(lock) {
                val all = lines.toList()
                if (tail == null || tail >= all.size) return all
                if (tail <= 0) return emptyList()
                return all.subList(all.size - tail, all.size)
            }
        }
    }

    val token: String = generateHexToken(32)
    private val serverSocket = ServerSocket(0, 64, InetAddress.getByName("127.0.0.1"))
    val port: Int = serverSocket.localPort
    val uid: Int = try { Os.getuid() } catch (_: Throwable) { -1 }
    val pid: Int = try { Os.getpid() } catch (_: Throwable) { -1 }
    val userLabel: String = when (uid) {
        0 -> "root"
        2000 -> "shell"
        else -> "uid_$uid"
    }

    private val closed = AtomicBoolean(false)
    private val pool = Executors.newCachedThreadPool()
    private val procs = ConcurrentHashMap<String, ManagedChild>()

    init {
        Thread({ acceptLoop() }, "mcp-priv-accept").apply {
            isDaemon = true
            start()
        }
    }

    fun bridgeInfoJson(): String {
        return JSONObject().apply {
            put("ok", true)
            put("port", port)
            put("token", token)
            put("uid", uid)
            put("pid", pid)
            put("user", userLabel)
        }.toString()
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        stopAllProcesses()
        try { serverSocket.close() } catch (_: Throwable) {}
        pool.shutdownNow()
    }

    private fun acceptLoop() {
        while (!closed.get()) {
            try {
                val client = serverSocket.accept()
                client.tcpNoDelay = true
                client.soTimeout = 650000
                pool.execute { handleClient(client) }
            } catch (_: Throwable) {
                if (closed.get()) break
            }
        }
    }

    private fun handleClient(sock: Socket) {
        try {
            sock.use { s ->
                val ins = BufferedInputStream(s.getInputStream(), 16384)
                val outs = BufferedOutputStream(s.getOutputStream(), 16384)

                val reqLine = readAsciiLine(ins) ?: return
                val parts = reqLine.split(' ')
                if (parts.size < 2) {
                    writeJson(outs, 400, JSONObject().put("ok", false).put("error", "Bad request"))
                    return
                }
                val method = parts[0].uppercase()
                val rawTarget = parts[1]
                val path = rawTarget.substringBefore('?')

                val headers = HashMap<String, String>()
                while (true) {
                    val line = readAsciiLine(ins) ?: break
                    if (line.isEmpty()) break
                    val colon = line.indexOf(':')
                    if (colon > 0) {
                        val k = line.substring(0, colon).trim().lowercase()
                        val v = line.substring(colon + 1).trim()
                        headers[k] = v
                    }
                }

                val supplied = headers["x-mcp-priv-token"] ?: ""
                if (!MessageDigest.isEqual(
                        supplied.toByteArray(StandardCharsets.UTF_8),
                        token.toByteArray(StandardCharsets.UTF_8)
                    )
                ) {
                    writeJson(outs, 403, JSONObject().put("ok", false).put("error", "Forbidden"))
                    return
                }

                val contentLen = headers["content-length"]?.toIntOrNull()?.coerceAtLeast(0) ?: 0
                val bodyBytes = if (contentLen > 0) readExactBytes(ins, contentLen) else ByteArray(0)

                dispatch(method, path, headers, bodyBytes, outs)
            }
        } catch (_: Throwable) {}
    }

    private fun dispatch(
        method: String,
        path: String,
        headers: Map<String, String>,
        bodyBytes: ByteArray,
        outs: BufferedOutputStream
    ) {
        try {
            if (method == "GET" && path == "/ping") {
                writeJson(
                    outs,
                    200,
                    JSONObject()
                        .put("ok", true)
                        .put("uid", uid)
                        .put("pid", pid)
                        .put("user", userLabel)
                )
                return
            }

            if (method == "POST" && path == "/fs/write") {
                handleFsWrite(headers, bodyBytes, outs)
                return
            }

            val reqJson = if (bodyBytes.isNotEmpty()) {
                JSONObject(String(bodyBytes, StandardCharsets.UTF_8))
            } else {
                JSONObject()
            }

            when (path) {
                "/fs/stat" -> writeJson(outs, 200, handleFsStat(reqJson))
                "/fs/list" -> writeJson(outs, 200, handleFsList(reqJson))
                "/fs/read" -> handleFsRead(reqJson, outs)
                "/fs/op" -> writeJson(outs, 200, handleFsOp(reqJson))
                "/proc/start" -> writeJson(outs, 200, handleProcStart(reqJson))
                "/proc/wait" -> writeJson(outs, 200, handleProcWait(reqJson))
                "/proc/manage" -> writeJson(outs, 200, handleProcManage(reqJson))
                "/proc/stop_all" -> {
                    stopAllProcesses()
                    writeJson(outs, 200, JSONObject().put("ok", true))
                }
                else -> writeJson(outs, 404, JSONObject().put("ok", false).put("error", "Not found: $path"))
            }
        } catch (t: Throwable) {
            writeJson(
                outs,
                500,
                JSONObject()
                    .put("ok", false)
                    .put("error", "${t.javaClass.simpleName}: ${t.message ?: t.toString()}")
            )
        }
    }

    private fun handleFsStat(req: JSONObject): JSONObject {
        val target = req.optString("path", "")
        if (target.isEmpty()) return JSONObject().put("ok", false).put("error", "Missing path")
        val f = File(target)
        try {
            val st = Os.stat(target)
            val modeType = st.st_mode and 0xF000
            val isDir = modeType == 0x4000
            val isReg = modeType == 0x8000
            val typeStr = when {
                isDir -> "directory"
                isReg -> "file"
                f.isDirectory -> "directory"
                else -> "file"
            }
            return JSONObject()
                .put("ok", true)
                .put("exists", true)
                .put("type", typeStr)
                .put("size", st.st_size)
                .put("mtime_ms", st.st_mtime * 1000L)
                .put("can_read", f.canRead() || uid == 0)
                .put("can_write", f.canWrite() || uid == 0)
        } catch (_: Throwable) {
            if (f.exists()) {
                return JSONObject()
                    .put("ok", true)
                    .put("exists", true)
                    .put("type", if (f.isDirectory) "directory" else "file")
                    .put("size", f.length())
                    .put("mtime_ms", f.lastModified())
                    .put("can_read", f.canRead())
                    .put("can_write", f.canWrite())
            }
            return JSONObject()
                .put("ok", true)
                .put("exists", false)
                .put("type", "not_found")
                .put("size", 0L)
                .put("mtime_ms", 0L)
        }
    }

    private fun handleFsList(req: JSONObject): JSONObject {
        val target = req.optString("path", "")
        val dir = File(target)
        val children = dir.listFiles()
            ?: return JSONObject()
                .put("ok", false)
                .put("error", if (!dir.exists()) "Not a directory: $target" else "Permission denied: $target")
        val arr = JSONArray()
        for (ch in children) {
            val isDir = try {
                ch.isDirectory
            } catch (_: Throwable) {
                false
            }
            val size = if (isDir) 0L else try { ch.length() } catch (_: Throwable) { 0L }
            val mtime = try { ch.lastModified() } catch (_: Throwable) { 0L }
            arr.put(
                JSONObject()
                    .put("name", ch.name)
                    .put("path", ch.absolutePath)
                    .put("type", if (isDir) "directory" else "file")
                    .put("size", size)
                    .put("mtime_ms", mtime)
            )
        }
        return JSONObject().put("ok", true).put("entries", arr)
    }

    private fun handleFsRead(req: JSONObject, outs: BufferedOutputStream) {
        val target = req.optString("path", "")
        val maxBytes = req.optLong("max_bytes", 32L * 1024L * 1024L)
        val f = File(target)
        if (!f.exists() || !f.isFile) {
            writeJson(outs, 404, JSONObject().put("ok", false).put("error", "Not a file or does not exist: $target"))
            return
        }
        val len = f.length()
        if (len > maxBytes) {
            writeJson(outs, 413, JSONObject().put("ok", false).put("error", "File exceeds max read limit ($len > $maxBytes bytes)"))
            return
        }
        val data = FileInputStream(f).use { it.readBytes() }
        writeRawResponse(outs, 200, "application/octet-stream", data)
    }

    private fun handleFsWrite(
        headers: Map<String, String>,
        bodyBytes: ByteArray,
        outs: BufferedOutputStream
    ) {
        val b64Path = headers["x-target-path-b64"] ?: ""
        if (b64Path.isEmpty()) {
            writeJson(outs, 400, JSONObject().put("ok", false).put("error", "Missing X-Target-Path-B64"))
            return
        }
        val targetPath = String(
            Base64.decode(b64Path, Base64.URL_SAFE or Base64.NO_WRAP),
            StandardCharsets.UTF_8
        )
        val createParents = (headers["x-create-parents"] ?: "1") == "1"
        val f = File(targetPath)
        if (createParents) {
            f.parentFile?.mkdirs()
        }
        FileOutputStream(f, false).use { fos ->
            fos.write(bodyBytes)
            fos.flush()
            try { fos.fd.sync() } catch (_: Throwable) {}
        }
        writeJson(outs, 200, JSONObject().put("ok", true).put("written", bodyBytes.size))
    }

    private fun handleFsOp(req: JSONObject): JSONObject {
        val action = req.optString("action", "")
        val srcPath = req.optString("src", "")
        val dstPath = req.optString("dst", "")
        val overwrite = req.optBoolean("overwrite", false)

        if (srcPath.isEmpty()) return JSONObject().put("ok", false).put("error", "Missing src")
        val src = File(srcPath)

        when (action) {
            "mkdirs" -> {
                src.mkdirs()
                return JSONObject().put("ok", src.exists() && src.isDirectory)
            }
            "delete" -> {
                if (!src.exists()) return JSONObject().put("ok", true)
                val ok = deleteRecursivelySafe(src)
                return if (ok) JSONObject().put("ok", true)
                else JSONObject().put("ok", false).put("error", "Failed to delete $srcPath")
            }
            "copy", "move" -> {
                if (!src.exists()) {
                    return JSONObject().put("ok", false).put("error", "Source does not exist: $srcPath")
                }
                if (dstPath.isEmpty()) {
                    return JSONObject().put("ok", false).put("error", "Missing dst")
                }
                val dst = File(dstPath)
                if (dst.exists()) {
                    if (!overwrite) {
                        return JSONObject().put("ok", false).put("error", "Destination exists: $dstPath")
                    }
                    deleteRecursivelySafe(dst)
                }
                dst.parentFile?.mkdirs()
                if (action == "move") {
                    if (src.renameTo(dst)) {
                        return JSONObject().put("ok", true)
                    }
                    copyRecursivelySafe(src, dst)
                    deleteRecursivelySafe(src)
                    return JSONObject().put("ok", true)
                } else {
                    copyRecursivelySafe(src, dst)
                    return JSONObject().put("ok", true)
                }
            }
            else -> return JSONObject().put("ok", false).put("error", "Unsupported action: $action")
        }
    }

    private fun deleteRecursivelySafe(f: File): Boolean {
        try {
            val st = Os.lstat(f.absolutePath)
            val isSymlink = (st.st_mode and 0xF000) == 0xA000
            if (!isSymlink && f.isDirectory) {
                f.listFiles()?.forEach { deleteRecursivelySafe(it) }
            }
        } catch (_: Throwable) {
            if (f.isDirectory) {
                f.listFiles()?.forEach { deleteRecursivelySafe(it) }
            }
        }
        return f.delete()
    }

    private fun copyRecursivelySafe(src: File, dst: File) {
        if (src.isDirectory) {
            dst.mkdirs()
            src.listFiles()?.forEach { ch ->
                copyRecursivelySafe(ch, File(dst, ch.name))
            }
        } else {
            dst.parentFile?.mkdirs()
            FileInputStream(src).use { ins ->
                FileOutputStream(dst, false).use { outs ->
                    ins.copyTo(outs, 32768)
                    outs.flush()
                }
            }
        }
    }

    private fun resolveShellExe(shell: String): String {
        if (shell == "bash" && File("/system/bin/bash").canExecute()) return "/system/bin/bash"
        if (shell == "bash" && File("/bin/bash").canExecute()) return "/bin/bash"
        if (File("/system/bin/sh").exists()) return "/system/bin/sh"
        return "/bin/sh"
    }

    private fun extractJavaProcessPid(p: Process): Int {
        try {
            val m = Process::class.java.getMethod("pid")
            val v = m.invoke(p)
            if (v is Number) return v.toInt()
        } catch (_: Throwable) {}
        try {
            val f = p.javaClass.getDeclaredField("pid")
            f.isAccessible = true
            return f.getInt(p)
        } catch (_: Throwable) {}
        return -1
    }

    private fun handleProcStart(req: JSONObject): JSONObject {
        val command = req.optString("command", "")
        var workDir = req.optString("cwd", "").trim()
        val shell = req.optString("shell", "auto")

        var cwdFile = if (workDir.isNotEmpty()) File(workDir) else File("/data/local/tmp")
        if (!cwdFile.exists() || !cwdFile.isDirectory || (uid != 0 && !cwdFile.canExecute())) {
            val sd = File("/sdcard")
            cwdFile = if (sd.exists() && sd.canExecute()) sd else File("/data/local/tmp")
            workDir = cwdFile.absolutePath
        }

        val shExe = resolveShellExe(shell)
        val pb = ProcessBuilder(shExe, "-c", command)
        pb.directory(cwdFile)

        val envMap = pb.environment()
        val basePath = envMap["PATH"] ?: "/product/bin:/apex/com.android.runtime/bin:/system_ext/bin:/system/bin:/system/xbin:/vendor/bin"
        envMap["PATH"] = if (uid == 0) {
            "/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:$basePath"
        } else {
            basePath
        }
        envMap.putIfAbsent("HOME", "/data/local/tmp")
        envMap.putIfAbsent("TERM", "xterm-256color")
        envMap.putIfAbsent("LANG", "en_US.UTF-8")

        val extraEnv = req.optJSONObject("env")
        if (extraEnv != null) {
            val keys = extraEnv.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                envMap[k] = extraEnv.optString(k, "")
            }
        }

        val proc = pb.start()
        val childPid = extractJavaProcessPid(proc)
        val procId = generateHexToken(4)
        val child = ManagedChild(
            id = procId,
            command = command,
            cwd = cwdFile.absolutePath,
            proc = proc,
            pid = childPid,
            startedAtMs = System.currentTimeMillis()
        )
        procs[procId] = child

        pool.execute {
            pumpStreamLines(proc.inputStream, child)
            synchronized(child.lock) {
                child.stdoutDone = true
                child.lock.notifyAll()
            }
        }
        pool.execute {
            pumpStreamLines(proc.errorStream, child)
            synchronized(child.lock) {
                child.stderrDone = true
                child.lock.notifyAll()
            }
        }
        pool.execute {
            val rc = try { proc.waitFor() } catch (_: Throwable) { -1 }
            val deadline = System.currentTimeMillis() + 150L
            synchronized(child.lock) {
                while ((!child.stdoutDone || !child.stderrDone) && System.currentTimeMillis() < deadline) {
                    val rem = deadline - System.currentTimeMillis()
                    if (rem > 0) try { child.lock.wait(rem) } catch (_: Throwable) {}
                }
                child.exitCode = rc
                child.endedAtMs = System.currentTimeMillis()
                child.lock.notifyAll()
            }
        }

        return JSONObject()
            .put("ok", true)
            .put("process_id", procId)
            .put("pid", childPid)
            .put("cwd", cwdFile.absolutePath)
    }

    private fun pumpStreamLines(stream: InputStream, child: ManagedChild) {
        try {
            stream.bufferedReader(StandardCharsets.UTF_8).useLines { seq ->
                for (line in seq) {
                    child.appendLine(line)
                }
            }
        } catch (_: Throwable) {}
    }

    private fun handleProcWait(req: JSONObject): JSONObject {
        val procId = req.optString("process_id", "")
        val timeoutMs = req.optLong("timeout_ms", 30000L).coerceIn(50L, 605000L)
        val child = procs[procId]
            ?: return JSONObject().put("ok", false).put("error", "Unknown process_id: $procId")

        val deadline = System.currentTimeMillis() + timeoutMs
        synchronized(child.lock) {
            while (child.exitCode == null) {
                val rem = deadline - System.currentTimeMillis()
                if (rem <= 0L) break
                try { child.lock.wait(rem) } catch (_: Throwable) { break }
            }
        }

        val rc = child.exitCode
        val endMs = child.endedAtMs ?: System.currentTimeMillis()
        val elapsedSec = (endMs - child.startedAtMs) / 1000.0
        val arr = JSONArray()
        for (l in child.snapshotLines()) arr.put(l)

        return JSONObject()
            .put("ok", true)
            .put("process_id", child.id)
            .put("pid", child.pid)
            .put("cwd", child.cwd)
            .put("running", rc == null)
            .put("exit_code", rc ?: JSONObject.NULL)
            .put("elapsed_sec", elapsedSec)
            .put("lines", arr)
    }

    private fun handleProcManage(req: JSONObject): JSONObject {
        val action = req.optString("action", "list")
        if (action == "list") {
            val now = System.currentTimeMillis()
            val arr = JSONArray()
            for (ch in procs.values) {
                val endMs = ch.endedAtMs ?: now
                val elapsed = ((endMs - ch.startedAtMs) / 10.0).toInt() / 100.0
                val rc = ch.exitCode
                arr.put(
                    JSONObject()
                        .put("process_id", ch.id)
                        .put("pid", ch.pid)
                        .put("command", ch.command)
                        .put("cwd", ch.cwd)
                        .put("status", if (rc == null) "running" else "exited ($rc)")
                        .put("buffered_lines", ch.snapshotLines().size)
                        .put("elapsed_sec", elapsed)
                        .put("privileged_uid", uid)
                )
            }
            return JSONObject().put("ok", true).put("processes", arr)
        }

        val procId = req.optString("process_id", "")
        val child = procs[procId]
            ?: return JSONObject().put("ok", false).put("error", "Unknown process_id: $procId")

        when (action) {
            "read" -> {
                val tail = req.optInt("tail_lines", 100).coerceIn(1, 2000)
                val arr = JSONArray()
                for (l in child.snapshotLines(tail)) arr.put(l)
                val rc = child.exitCode
                return JSONObject()
                    .put("ok", true)
                    .put("process_id", child.id)
                    .put("pid", child.pid)
                    .put("running", rc == null)
                    .put("exit_code", rc ?: JSONObject.NULL)
                    .put("lines", arr)
            }
            "write" -> {
                if (child.exitCode != null) {
                    return JSONObject().put("ok", false).put("error", "Process already exited (${child.exitCode})")
                }
                val text = req.optString("input_text", "")
                val payload = if (text.endsWith("\n")) text else "$text\n"
                return try {
                    child.proc.outputStream.write(payload.toByteArray(StandardCharsets.UTF_8))
                    child.proc.outputStream.flush()
                    JSONObject().put("ok", true).put("written", payload.length)
                } catch (t: Throwable) {
                    JSONObject().put("ok", false).put("error", t.message ?: t.toString())
                }
            }
            "kill" -> {
                killProcessTree(child)
                return JSONObject().put("ok", true).put("pid", child.pid)
            }
            else -> return JSONObject().put("ok", false).put("error", "Unsupported manage action: $action")
        }
    }

    private fun killProcessTree(child: ManagedChild) {
        if (child.pid > 0) {
            try {
                ProcessBuilder("/system/bin/sh", "-c", "pkill -KILL -P ${child.pid} 2>/dev/null; kill -9 ${child.pid} 2>/dev/null")
                    .start()
                    .waitFor()
            } catch (_: Throwable) {}
        }
        try {
            child.proc.destroyForcibly()
        } catch (_: Throwable) {
            try { child.proc.destroy() } catch (_: Throwable) {}
        }
    }

    private fun stopAllProcesses() {
        for (ch in procs.values) {
            if (ch.exitCode == null) {
                killProcessTree(ch)
            }
        }
    }

    companion object {
        private val rng = SecureRandom()

        fun generateHexToken(byteLen: Int): String {
            val b = ByteArray(byteLen)
            rng.nextBytes(b)
            val sb = StringBuilder(byteLen * 2)
            for (v in b) {
                sb.append(String.format("%02x", v.toInt() and 0xFF))
            }
            return sb.toString()
        }

        private fun readAsciiLine(ins: InputStream): String? {
            val baos = ByteArrayOutputStream(128)
            var sawAny = false
            while (true) {
                val c = ins.read()
                if (c == -1) {
                    return if (sawAny) String(baos.toByteArray(), StandardCharsets.UTF_8).trimEnd('\r') else null
                }
                sawAny = true
                if (c == '\n'.code) break
                baos.write(c)
                if (baos.size() > 32768) break
            }
            return String(baos.toByteArray(), StandardCharsets.UTF_8).trimEnd('\r')
        }

        private fun readExactBytes(ins: InputStream, count: Int): ByteArray {
            val out = ByteArray(count)
            var off = 0
            while (off < count) {
                val r = ins.read(out, off, count - off)
                if (r < 0) throw EOFException("Unexpected EOF reading request body")
                off += r
            }
            return out
        }

        private fun writeJson(outs: BufferedOutputStream, code: Int, obj: JSONObject) {
            val bytes = obj.toString().toByteArray(StandardCharsets.UTF_8)
            writeRawResponse(outs, code, "application/json; charset=utf-8", bytes)
        }

        private fun writeRawResponse(
            outs: BufferedOutputStream,
            code: Int,
            contentType: String,
            body: ByteArray
        ) {
            val reason = when (code) {
                200 -> "OK"
                400 -> "Bad Request"
                403 -> "Forbidden"
                404 -> "Not Found"
                413 -> "Payload Too Large"
                else -> "Internal Server Error"
            }
            val header = "HTTP/1.1 $code $reason\r\n" +
                "Content-Type: $contentType\r\n" +
                "Content-Length: ${body.size}\r\n" +
                "Connection: close\r\n\r\n"
            outs.write(header.toByteArray(StandardCharsets.US_ASCII))
            if (body.isNotEmpty()) outs.write(body)
            outs.flush()
        }
    }
}