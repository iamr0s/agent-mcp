package com.iamr0s.agent_mcp_app;

interface IMcpPrivilegedService {
    void destroy() = 16777114;
    String getBridgeInfoJson() = 1;
}