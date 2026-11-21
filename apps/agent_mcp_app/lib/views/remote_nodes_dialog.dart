import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/console_backend.dart';
import '../theme/claude_theme.dart';

Future<void> showRemoteNodesManagerDialog(
  BuildContext context, {
  required ConsoleBackend backend,
  required ValueChanged<String> onToast,
  required Future<void> Function(String nodeId) onSwitchNode,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (ctx) => _RemoteNodesDialog(
      backend: backend,
      onToast: onToast,
      onSwitchNode: onSwitchNode,
    ),
  );
}

class _RemoteNodesDialog extends StatefulWidget {
  final ConsoleBackend backend;
  final ValueChanged<String> onToast;
  final Future<void> Function(String nodeId) onSwitchNode;

  const _RemoteNodesDialog({
    required this.backend,
    required this.onToast,
    required this.onSwitchNode,
  });

  @override
  State<_RemoteNodesDialog> createState() => _RemoteNodesDialogState();
}

class _RemoteNodesDialogState extends State<_RemoteNodesDialog> {
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();

  bool _formOpen = false;
  String? _editingId;
  bool _probing = false;
  bool _saving = false;
  String? _probeMsg;
  bool _probeOk = false;

  @override
  void initState() {
    super.initState();
    // Auto-open form if user has no remote nodes saved yet
    if (widget.backend.savedNodes.where((n) => !n.isLocal).isEmpty) {
      _formOpen = true;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _pwdCtrl.dispose();
    super.dispose();
  }

  void _startAdd() {
    setState(() {
      _editingId = null;
      _nameCtrl.clear();
      _urlCtrl.clear();
      _pwdCtrl.clear();
      _probeMsg = null;
      _formOpen = true;
    });
  }

  void _startEdit(ConsoleNodeProfile node) {
    setState(() {
      _editingId = node.id;
      _nameCtrl.text = node.name;
      _urlCtrl.text = node.baseUrl;
      _pwdCtrl.text = node.savedPassword;
      _probeMsg = null;
      _formOpen = true;
    });
  }

  Future<void> _probeDraft() async {
    final cleanUrl = normalizeRemoteBaseUrl(_urlCtrl.text);
    if (cleanUrl.isEmpty) {
      setState(() {
        _probeOk = false;
        _probeMsg = '请先输入远程电脑的域名或局域网 / Tailscale 地址';
      });
      return;
    }
    setState(() {
      _probing = true;
      _probeMsg = null;
    });
    try {
      final res = await widget.backend.checkHealth('$cleanUrl/health');
      final ok = res['ok'] == true;
      final ms = res['latency_ms'];
      final code = res['status_code'];
      if (mounted) {
        setState(() {
          _probeOk = ok;
          _probeMsg = ok
              ? '连通成功 · HTTP ${code ?? 200}${ms != null ? " · ${ms}ms" : ""}'
              : '未连通：${res['error'] ?? "HTTP ${code ?? "-"}"}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _probeOk = false;
          _probeMsg = '探测失败：$e';
        });
      }
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _saveAndConnect() async {
    final cleanUrl = normalizeRemoteBaseUrl(_urlCtrl.text);
    if (cleanUrl.isEmpty) {
      widget.onToast('请输入有效的远程节点地址');
      return;
    }
    setState(() => _saving = true);
    try {
      final entry = await widget.backend.upsertRemoteNode(
        id: _editingId,
        name: _nameCtrl.text.trim(),
        baseUrl: cleanUrl,
        savedPassword: _pwdCtrl.text,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      await widget.onSwitchNode(entry.id);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final nodes = widget.backend.savedNodes;
    final activeId = widget.backend.activeNode.id;
    final lanIps = widget.backend.deviceLanIps;

    return SafeArea(
      child: Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 680),
        child: ClaudeCard(
          radius: 22,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: ShapeDecoration(
                      color: c.clay.withValues(alpha: 0.12),
                      shape: claudeSuperellipse(11),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.hub_rounded,
                      size: 18,
                      color: c.clay,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '节点切换与远程连接档案',
                          style: serifTitleStyle(c, size: 17.5),
                        ),
                        Text(
                          '在本机服务与多台远程电脑 MCP 节点间随时切换',
                          style: sansStyle(c, size: 12, color: c.muted),
                        ),
                      ],
                    ),
                  ),
                  ClaudeButton(
                    label: '',
                    compact: true,
                    variant: ClaudeBtnVariant.ghost,
                    leading: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Divider(color: c.hairline, height: 1),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final node in nodes) ...[
                        _NodeProfileTile(
                          node: node,
                          isActive: node.id == activeId,
                          lanIps: node.isLocal ? lanIps : const [],
                          onConnect: () async {
                            Navigator.of(context).pop();
                            await widget.onSwitchNode(node.id);
                          },
                          onEdit: node.isLocal ? null : () => _startEdit(node),
                          onDelete: node.isLocal
                              ? null
                              : () async {
                                  final wasActive = node.id == activeId;
                                  await widget.backend.deleteRemoteNode(node.id);
                                  if (!mounted) return;
                                  setState(() {});
                                  widget.onToast('已移除节点「${node.name}」');
                                  if (wasActive) {
                                    await widget.onSwitchNode('local');
                                  }
                                },
                          onCopyEndpoint: (txt) {
                            Clipboard.setData(ClipboardData(text: txt));
                            widget.onToast('已复制地址：$txt');
                          },
                        ),
                        const SizedBox(height: 8),
                      ],
                      const SizedBox(height: 4),
                      if (!_formOpen)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: ClaudeButton(
                            label: '添加远程电脑节点',
                            leading: const Icon(Icons.add_rounded),
                            onPressed: _startAdd,
                          ),
                        ),
                      ClaudeCollapsible(
                        expanded: _formOpen,
                        builder: (_) => Container(
                          margin: const EdgeInsets.only(top: 6),
                          padding: const EdgeInsets.all(14),
                          decoration: ShapeDecoration(
                            color: c.paper3.withValues(alpha: 0.55),
                            shape: claudeSuperellipse(
                              14,
                              side: BorderSide(color: c.hairline),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      _editingId == null
                                          ? '新增远程电脑连接'
                                          : '编辑远程电脑连接',
                                      style: sansStyle(
                                        c,
                                        size: 13.5,
                                        weight: FontWeight.w600,
                                        color: c.ink,
                                      ),
                                    ),
                                  ),
                                  if (nodes.length > 1)
                                    ClaudeButton(
                                      label: '收起',
                                      compact: true,
                                      variant: ClaudeBtnVariant.ghost,
                                      onPressed: () =>
                                          setState(() => _formOpen = false),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              TextField(
                                controller: _nameCtrl,
                                style: sansStyle(c, size: 13, color: c.ink),
                                decoration: const InputDecoration(
                                  labelText: '节点名称',
                                  hintText: '例如：Omen 主力电脑 / 工作室台式机',
                                ),
                              ),
                              const SizedBox(height: 10),
                              TextField(
                                controller: _urlCtrl,
                                style: monoStyle(c, size: 12.5, color: c.ink),
                                decoration: const InputDecoration(
                                  labelText: '远程地址（公网 HTTPS / Tailscale / 局域网）',
                                  hintText:
                                      'https://omen-mcp.example.com 或 100.x.y.z:8000',
                                ),
                              ),
                              const SizedBox(height: 10),
                              ClaudePasswordField(
                                controller: _pwdCtrl,
                                hintText: '管理密码或 API Key（可选保存，免重复输入）',
                              ),
                              if (_probeMsg != null) ...[
                                const SizedBox(height: 10),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 7,
                                  ),
                                  decoration: ShapeDecoration(
                                    color: _probeOk ? c.sageBg : c.dangerBg,
                                    shape: claudeSuperellipse(10),
                                  ),
                                  child: Text(
                                    _probeMsg!,
                                    style: sansStyle(
                                      c,
                                      size: 12,
                                      weight: FontWeight.w500,
                                      color: _probeOk ? c.sage : c.danger,
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 12),
                              Wrap(
                                alignment: WrapAlignment.end,
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  ClaudeButton(
                                    label: _probing ? '探测中...' : '测试连通',
                                    compact: true,
                                    loading: _probing,
                                    leading: const Icon(
                                      Icons.network_check_rounded,
                                    ),
                                    onPressed: _saving ? null : _probeDraft,
                                  ),
                                  ClaudeButton(
                                    label: _saving ? '连接中...' : '保存并切换连接',
                                    compact: true,
                                    loading: _saving,
                                    variant: ClaudeBtnVariant.clay,
                                    leading: const Icon(Icons.link_rounded),
                                    onPressed:
                                        _probing ? null : _saveAndConnect,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

class _NodeProfileTile extends StatelessWidget {
  final ConsoleNodeProfile node;
  final bool isActive;
  final List<String> lanIps;
  final VoidCallback onConnect;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final ValueChanged<String> onCopyEndpoint;

  const _NodeProfileTile({
    required this.node,
    required this.isActive,
    required this.lanIps,
    required this.onConnect,
    required this.onCopyEndpoint,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final subText = node.isLocal
        ? (lanIps.isNotEmpty
            ? '本机内置引擎 · 局域网 ${lanIps.first}'
            : '本机内置 Dart 原生 MCP 服务引擎')
        : node.baseUrl;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: ShapeDecoration(
        color: isActive ? c.clay.withValues(alpha: 0.08) : c.paper2,
        shape: claudeSuperellipse(
          13,
          side: BorderSide(
            color: isActive ? c.clay.withValues(alpha: 0.45) : c.hairline,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            node.isLocal ? Icons.smartphone_rounded : Icons.dns_rounded,
            size: 18,
            color: isActive ? c.clay : c.muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      node.name,
                      style: sansStyle(
                        c,
                        size: 13.5,
                        weight: FontWeight.w600,
                        color: c.ink,
                      ),
                    ),
                    ClaudePill(
                      text: node.isLocal ? '本机' : '远程',
                      mono: false,
                      fg: isActive ? c.clay : c.muted,
                      bg: c.paper3,
                    ),
                    if (!node.isLocal && node.savedPassword.isNotEmpty)
                      ClaudePill(
                        text: '免密记忆',
                        mono: false,
                        fg: c.sage,
                        bg: c.sageBg,
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                GestureDetector(
                  onTap: node.isLocal
                      ? null
                      : () => onCopyEndpoint(node.baseUrl),
                  child: Text(
                    subText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(c, size: 11.5, color: c.muted),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (onEdit != null)
            ClaudeButton(
              label: '',
              compact: true,
              variant: ClaudeBtnVariant.ghost,
              tooltip: '编辑节点',
              leading: const Icon(Icons.edit_outlined, size: 15.5),
              onPressed: onEdit,
            ),
          if (onDelete != null)
            ClaudeButton(
              label: '',
              compact: true,
              variant: ClaudeBtnVariant.ghost,
              tooltip: '删除节点',
              leading: Icon(
                Icons.delete_outline_rounded,
                size: 16,
                color: c.danger,
              ),
              onPressed: onDelete,
            ),
          const SizedBox(width: 4),
          ClaudeButton(
            label: isActive ? '当前' : '切换',
            compact: true,
            variant: isActive ? ClaudeBtnVariant.ghost : ClaudeBtnVariant.clay,
            onPressed: isActive ? null : onConnect,
          ),
        ],
      ),
    );
  }
}