package com.iamr0s.agent_mcp_app

import android.content.Context
import androidx.annotation.Keep
import kotlin.system.exitProcess

@Keep
class McpShizukuUserService() : IMcpPrivilegedService.Stub() {
    private val loopback = PrivilegedLoopbackServer()

    @Keep
    constructor(@Suppress("UNUSED_PARAMETER") context: Context) : this()

    override fun destroy() {
        loopback.close()
        exitProcess(0)
    }

    override fun getBridgeInfoJson(): String {
        return loopback.bridgeInfoJson()
    }
}