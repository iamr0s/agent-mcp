package com.iamr0s.agent_mcp_app

import androidx.annotation.Keep
import kotlin.system.exitProcess

@Keep
object McpPrivilegedDaemonMain {
    @Keep
    @JvmStatic
    fun main(@Suppress("UNUSED_PARAMETER") args: Array<String>) {
        val loopback = PrivilegedLoopbackServer()
        println("MCP_PRIV_READY:${loopback.bridgeInfoJson()}")
        System.out.flush()
        try {
            val buf = ByteArray(256)
            while (true) {
                val r = System.`in`.read(buf)
                if (r < 0) break
            }
        } catch (_: Throwable) {
        } finally {
            loopback.close()
            exitProcess(0)
        }
    }
}