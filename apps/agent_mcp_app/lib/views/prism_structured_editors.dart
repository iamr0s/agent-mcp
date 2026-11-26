import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/console_backend.dart';
import '../theme/prism_theme.dart';

/// Default OAuth 2.1 callback redirect URI whitelist rules pre-populated when
/// callback whitelist mode is active by default (`oauth_allow_all_redirects = false`).
const List<String> kDefaultOAuthRedirectRules = <String>[
  'http://127.0.0.1:*/**',
  'http://localhost:*/**',
  'https://*.google.com/**',
  'https://vertexaisearch.cloud.google.com/**',
  'https://*.claude.ai/**',
  'https://claude.ai/**',
  'https://chatgpt.com/**',
  'https://*.openai.com/**',
  'cursor://**',
  'vscode://**',
];

/// Switch-driven row-by-row wildcard rule list editor used for both:
/// 1. OAuth 2.1 Allowed Callback Redirect URIs (`oauth_allow_all_redirects` + `oauth_redirect_uris`)
/// 2. Allowed Directory Whitelists (`allow_all_roots` + `roots`)
///
/// When [allowAll] is `true` (default), all addresses/directories are permitted while
/// preserving any configured [rules] in storage. Turning [allowAll] `false` smoothly
/// unfolds the row-by-row rule list editor with wildcard (`*`, `**`, `?`) support.
class PrismWildcardRuleListCard extends StatefulWidget {
  final Key? switchKey;
  final String switchTitle;
  final String switchSubtitleOn;
  final String switchSubtitleOff;
  final String badgeOnText;
  final String badgeOffPrefix;
  final bool allowAll;
  final ValueChanged<bool> onAllowAllChanged;
  final List<String> rules;
  final ValueChanged<List<String>> onRulesChanged;
  final String rowHintText;
  final List<(String label, String pattern)> quickPresets;
  final Future<String?> Function()? onPickDirectory;
  final String addRowLabel;

  const PrismWildcardRuleListCard({
    super.key,
    this.switchKey,
    required this.switchTitle,
    required this.switchSubtitleOn,
    required this.switchSubtitleOff,
    this.badgeOnText = '默认允许全部',
    this.badgeOffPrefix = '仅限白名单',
    required this.allowAll,
    required this.onAllowAllChanged,
    required this.rules,
    required this.onRulesChanged,
    required this.rowHintText,
    this.quickPresets = const [],
    this.onPickDirectory,
    this.addRowLabel = '添加一行规则',
  });

  @override
  State<PrismWildcardRuleListCard> createState() =>
      _PrismWildcardRuleListCardState();
}

class _PrismWildcardRuleListCardState extends State<PrismWildcardRuleListCard> {
  final List<TextEditingController> _ctrls = [];
  bool _internalMutating = false;

  @override
  void initState() {
    super.initState();
    _syncControllersFromWidget();
  }

  @override
  void didUpdateWidget(covariant PrismWildcardRuleListCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_internalMutating && !_listEquals(oldWidget.rules, widget.rules)) {
      _syncControllersFromWidget();
    }
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _syncControllersFromWidget() {
    final src = widget.rules.isEmpty ? <String>[''] : widget.rules;
    while (_ctrls.length > src.length) {
      _ctrls.removeLast().dispose();
    }
    for (var i = 0; i < src.length; i++) {
      if (i < _ctrls.length) {
        if (_ctrls[i].text != src[i]) {
          _ctrls[i].text = src[i];
        }
      } else {
        _ctrls.add(TextEditingController(text: src[i]));
      }
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  void _emitRules() {
    _internalMutating = true;
    final cleaned = _ctrls
        .map((c) => c.text.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    widget.onRulesChanged(cleaned);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _internalMutating = false;
    });
  }

  void _addRow([String initial = '']) {
    setState(() {
      if (_ctrls.length == 1 && _ctrls.first.text.trim().isEmpty && initial.isNotEmpty) {
        _ctrls.first.text = initial;
      } else {
        _ctrls.add(TextEditingController(text: initial));
      }
    });
    _emitRules();
  }

  void _removeRow(int index) {
    setState(() {
      if (_ctrls.length <= 1) {
        _ctrls.first.clear();
      } else {
        _ctrls.removeAt(index).dispose();
      }
    });
    _emitRules();
  }

  Future<void> _pickIntoRow(int index) async {
    final picker = widget.onPickDirectory;
    if (picker == null) return;
    final chosen = await picker();
    if (chosen == null || chosen.trim().isEmpty || !mounted) return;
    setState(() {
      _ctrls[index].text = chosen.trim();
    });
    _emitRules();
  }

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final nonEmptyCount =
        _ctrls.map((x) => x.text.trim()).where((s) => s.isNotEmpty).length;

    return CustomPaint(
      foregroundPainter: PrismSpecularRimPainter(
        radius: 20,
        isDark: c.isDark,
        intensity: c.isDark ? 0.68 : 0.88,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: ShapeDecoration(
          color: c.paper2,
          shape: prismSuperellipse(
            20,
            side: BorderSide(color: c.hairline.withValues(alpha: 0.65)),
          ),
          shadows: c.whisperShadow,
        ),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          widget.switchTitle,
                          style: sansStyle(
                            c,
                            size: 13.2,
                            weight: FontWeight.w600,
                            color: c.ink,
                          ),
                        ),
                        PrismPill(
                          text: widget.allowAll
                              ? widget.badgeOnText
                              : '${widget.badgeOffPrefix} ($nonEmptyCount 条)',
                          mono: false,
                          fg: widget.allowAll ? c.sage : c.clay,
                          bg: widget.allowAll
                              ? c.sageBg
                              : c.clay.withValues(alpha: 0.12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.allowAll
                          ? widget.switchSubtitleOn
                          : widget.switchSubtitleOff,
                      style: sansStyle(c, size: 11.8, color: c.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              PrismSwitch(
                key: widget.switchKey,
                value: widget.allowAll,
                onChanged: widget.onAllowAllChanged,
              ),
            ],
          ),
          PrismCollapsible(
            expanded: !widget.allowAll,
            builder: (_) => Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Divider(height: 1, color: c.hairline),
                  const SizedBox(height: 10),
                  if (nonEmptyCount == 0)
                    Container(
                      margin: const EdgeInsets.only(bottom: 9),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      decoration: ShapeDecoration(
                        color: c.clay.withValues(alpha: 0.10),
                        shape: prismSuperellipse(10),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 14,
                            color: c.clay,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              '已关闭全部放行：请逐行添加允许的规则（支持 * 单级、** 多级与 ? 通配符）。列表为空时将默认拦截未匹配请求。',
                              style: sansStyle(
                                c,
                                size: 11.4,
                                color: c.clay,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  for (var i = 0; i < _ctrls.length; i++) ...[
                    if (i > 0) const SizedBox(height: 7),
                    Row(
                      children: [
                        Container(
                          width: 22,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 6),
                          child: Text(
                            '${i + 1}.',
                            style: monoStyle(c, size: 11, color: c.meta),
                          ),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _ctrls[i],
                            onChanged: (_) {
                              setState(() {});
                              _emitRules();
                            },
                            style: monoStyle(c, size: 12.2, color: c.ink),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: widget.rowHintText,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 11,
                                vertical: 9,
                              ),
                            ),
                          ),
                        ),
                        if (widget.onPickDirectory != null) ...[
                          const SizedBox(width: 6),
                          PrismButton(
                            label: '',
                            compact: true,
                            tooltip: '浏览选择文件夹',
                            leading: const Icon(
                              Icons.folder_open_rounded,
                              size: 15.5,
                            ),
                            onPressed: () => _pickIntoRow(i),
                          ),
                        ],
                        const SizedBox(width: 6),
                        PrismButton(
                          label: '',
                          compact: true,
                          variant: PrismBtnVariant.ghost,
                          tooltip: '删除此行',
                          leading: Icon(
                            Icons.remove_circle_outline_rounded,
                            size: 16,
                            color: c.danger,
                          ),
                          onPressed: () => _removeRow(i),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 9),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      PrismButton(
                        label: widget.addRowLabel,
                        compact: true,
                        variant: PrismBtnVariant.clay,
                        leading: const Icon(Icons.add_rounded, size: 15),
                        onPressed: () => _addRow(),
                      ),
                      if (widget.onPickDirectory != null)
                        PrismButton(
                          label: '选择文件夹添加',
                          compact: true,
                          leading: const Icon(
                            Icons.create_new_folder_outlined,
                            size: 15,
                          ),
                          onPressed: () async {
                            final chosen = await widget.onPickDirectory!();
                            if (chosen != null && chosen.trim().isNotEmpty) {
                              _addRow(chosen.trim());
                            }
                          },
                        ),
                      for (final preset in widget.quickPresets)
                        PrismButton(
                          label: '+ ${preset.$1}',
                          compact: true,
                          variant: PrismBtnVariant.neutral,
                          onPressed: () => _addRow(preset.$2),
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
    );
  }
}

/// Structured row-by-row String list editor (replaces multi-line `args` textarea).
class PrismStringListEditor extends StatefulWidget {
  final List<String> values;
  final ValueChanged<List<String>> onChanged;
  final String hintText;
  final String addLabel;

  const PrismStringListEditor({
    super.key,
    required this.values,
    required this.onChanged,
    this.hintText = '输入参数，如 -y 或 @modelcontextprotocol/server-memory',
    this.addLabel = '添加参数',
  });

  @override
  State<PrismStringListEditor> createState() => _PrismStringListEditorState();
}

class _PrismStringListEditorState extends State<PrismStringListEditor> {
  final List<TextEditingController> _ctrls = [];
  bool _mutating = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant PrismStringListEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_mutating && oldWidget.values.join('\u0000') != widget.values.join('\u0000')) {
      _sync();
    }
  }

  void _sync() {
    final src = widget.values.isEmpty ? <String>[''] : widget.values;
    while (_ctrls.length > src.length) {
      _ctrls.removeLast().dispose();
    }
    for (var i = 0; i < src.length; i++) {
      if (i < _ctrls.length) {
        if (_ctrls[i].text != src[i]) _ctrls[i].text = src[i];
      } else {
        _ctrls.add(TextEditingController(text: src[i]));
      }
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  void _emit() {
    _mutating = true;
    widget.onChanged(
      _ctrls.map((c) => c.text.trim()).where((s) => s.isNotEmpty).toList(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _mutating = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _ctrls.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrls[i],
                  onChanged: (_) => _emit(),
                  style: monoStyle(c, size: 12.2, color: c.ink),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: i == 0 ? widget.hintText : '参数 #${i + 1}',
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              PrismButton(
                label: '',
                compact: true,
                variant: PrismBtnVariant.ghost,
                tooltip: '移除参数',
                leading: Icon(
                  Icons.remove_circle_outline_rounded,
                  size: 15.5,
                  color: c.muted,
                ),
                onPressed: () {
                  setState(() {
                    if (_ctrls.length <= 1) {
                      _ctrls.first.clear();
                    } else {
                      _ctrls.removeAt(i).dispose();
                    }
                  });
                  _emit();
                },
              ),
            ],
          ),
        ],
        const SizedBox(height: 7),
        PrismButton(
          label: widget.addLabel,
          compact: true,
          leading: const Icon(Icons.add_rounded, size: 14.5),
          onPressed: () {
            setState(() => _ctrls.add(TextEditingController()));
          },
        ),
      ],
    );
  }
}

/// Structured Key-Value row editor with per-row secret masking toggle
/// (replaces raw `env` and `headers` multi-line textareas).
class PrismKeyValueListEditor extends StatefulWidget {
  final Map<String, String> entries;
  final ValueChanged<Map<String, String>> onChanged;
  final String keyHint;
  final String valueHint;
  final String addLabel;

  const PrismKeyValueListEditor({
    super.key,
    required this.entries,
    required this.onChanged,
    this.keyHint = 'KEY',
    this.valueHint = 'VALUE（支持 \${ENV:VAR}）',
    this.addLabel = '添加一行',
  });

  @override
  State<PrismKeyValueListEditor> createState() =>
      _PrismKeyValueListEditorState();
}

class _PrismKeyValueListEditorState extends State<PrismKeyValueListEditor> {
  final List<(TextEditingController k, TextEditingController v, bool obscure)>
      _rows = [];
  bool _mutating = false;

  static bool _looksSensitiveKey(String key) {
    final u = key.toUpperCase();
    return u.contains('KEY') ||
        u.contains('TOKEN') ||
        u.contains('SECRET') ||
        u.contains('AUTH') ||
        u.contains('PASS');
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant PrismKeyValueListEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_mutating && jsonEncode(oldWidget.entries) != jsonEncode(widget.entries)) {
      _sync();
    }
  }

  void _sync() {
    for (final r in _rows) {
      r.$1.dispose();
      r.$2.dispose();
    }
    _rows.clear();
    if (widget.entries.isEmpty) {
      _rows.add((TextEditingController(), TextEditingController(), false));
    } else {
      for (final e in widget.entries.entries) {
        _rows.add((
          TextEditingController(text: e.key),
          TextEditingController(text: e.value),
          _looksSensitiveKey(e.key),
        ));
      }
    }
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.$1.dispose();
      r.$2.dispose();
    }
    super.dispose();
  }

  void _emit() {
    _mutating = true;
    final out = <String, String>{};
    for (final r in _rows) {
      final k = r.$1.text.trim();
      if (k.isNotEmpty) {
        out[k] = r.$2.text.trim();
      }
    }
    widget.onChanged(out);
    WidgetsBinding.instance.addPostFrameCallback((_) => _mutating = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                flex: 4,
                child: TextField(
                  controller: _rows[i].$1,
                  onChanged: (txt) {
                    if (_looksSensitiveKey(txt) && !_rows[i].$3) {
                      setState(() {
                        _rows[i] = (_rows[i].$1, _rows[i].$2, true);
                      });
                    }
                    _emit();
                  },
                  style: monoStyle(c, size: 12, color: c.ink),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: widget.keyHint,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                flex: 6,
                child: TextField(
                  controller: _rows[i].$2,
                  obscureText: _rows[i].$3,
                  onChanged: (_) => _emit(),
                  style: monoStyle(c, size: 12, color: c.ink),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: widget.valueHint,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8.5,
                    ),
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    suffixIcon: IconButton(
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      iconSize: 15,
                      tooltip: _rows[i].$3 ? '显示明文' : '隐藏敏感值',
                      onPressed: () {
                        setState(() {
                          _rows[i] = (_rows[i].$1, _rows[i].$2, !_rows[i].$3);
                        });
                      },
                      icon: Icon(
                        _rows[i].$3
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        color: c.meta,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              PrismButton(
                label: '',
                compact: true,
                variant: PrismBtnVariant.ghost,
                tooltip: '删除此行',
                leading: Icon(
                  Icons.remove_circle_outline_rounded,
                  size: 15.5,
                  color: c.muted,
                ),
                onPressed: () {
                  setState(() {
                    if (_rows.length <= 1) {
                      _rows.first.$1.clear();
                      _rows.first.$2.clear();
                    } else {
                      final old = _rows.removeAt(i);
                      old.$1.dispose();
                      old.$2.dispose();
                    }
                  });
                  _emit();
                },
              ),
            ],
          ),
        ],
        const SizedBox(height: 7),
        PrismButton(
          label: widget.addLabel,
          compact: true,
          leading: const Icon(Icons.add_rounded, size: 14.5),
          onPressed: () {
            setState(() {
              _rows.add((
                TextEditingController(),
                TextEditingController(),
                false,
              ));
            });
          },
        ),
      ],
    );
  }
}

/// 1-Click AI Client Onboarding Dialog (Claude Desktop, Cursor, VS Code, Windsurf, Claude Code CLI).
class ClientOnboardingDialog extends StatefulWidget {
  final ConsoleBackend backend;
  final String serverKey;
  final String mcpUrl;
  final String transport;
  final String? bearerToken;
  final ValueChanged<String> onToast;

  const ClientOnboardingDialog({
    super.key,
    required this.backend,
    required this.serverKey,
    required this.mcpUrl,
    this.transport = 'http',
    this.bearerToken,
    required this.onToast,
  });

  @override
  State<ClientOnboardingDialog> createState() => _ClientOnboardingDialogState();
}

class _ClientOnboardingDialogState extends State<ClientOnboardingDialog> {
  late final TextEditingController _keyCtrl =
      TextEditingController(text: widget.serverKey);
  List<Map<String, dynamic>> _targets = const [];
  bool _loading = true;
  String? _applyingId;

  @override
  void initState() {
    super.initState();
    _loadTargets();
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadTargets() async {
    setState(() => _loading = true);
    try {
      final res = await widget.backend.getClientOnboardingTargets();
      final list = ((res['targets'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (mounted) {
        setState(() {
          _targets = list;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _applyTarget(Map<String, dynamic> t) async {
    final cid = (t['id'] ?? '').toString();
    final label = (t['label'] ?? cid).toString();
    setState(() => _applyingId = cid);
    try {
      final res = await widget.backend.applyClientOnboarding(
        clientId: cid,
        serverKey: _keyCtrl.text.trim().isEmpty
            ? 'agent-mcp'
            : _keyCtrl.text.trim(),
        mcpUrl: widget.mcpUrl,
        transport: widget.transport,
        bearerToken: widget.bearerToken,
      );
      if (res['ok'] == true) {
        widget.onToast('已写入 $label 配置（原配置已自动备份 .bak）');
        await _loadTargets();
      } else {
        widget.onToast('写入失败：${res['error'] ?? ''}');
      }
    } finally {
      if (mounted) setState(() => _applyingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    return Dialog(
      backgroundColor: c.paper,
      elevation: 0,
      shape: prismSuperellipse(
        28,
        side: BorderSide(color: c.hairline.withValues(alpha: 0.72)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const PrismSparkIcon(size: 18),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      '一键接入本地 AI 客户端',
                      style: serifTitleStyle(c, size: 18),
                    ),
                  ),
                  PrismButton(
                    label: '关闭',
                    compact: true,
                    variant: PrismBtnVariant.ghost,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '自动合并写入客户端配置文件并生成 .bak 安全备份，无需手动编辑 JSON。',
                style: sansStyle(c, size: 12.2, color: c.muted),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  SizedBox(
                    width: 92,
                    child: Text(
                      '挂载键名',
                      style: sansStyle(c, size: 12.5, color: c.muted),
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _keyCtrl,
                      style: monoStyle(c, size: 12.4, color: c.ink),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'agent-mcp',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 7,
                ),
                decoration: ShapeDecoration(
                  color: c.recessed,
                  shape: prismSuperellipse(10),
                ),
                child: SelectableText(
                  widget.mcpUrl,
                  maxLines: 1,
                  style: monoStyle(c, size: 11.6, color: c.clay),
                ),
              ),
              const SizedBox(height: 14),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: PrismSparkIcon(size: 26)),
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: PrismListGroup(
                      children: [
                        for (final t in _targets)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Wrap(
                                        spacing: 6,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          Text(
                                            '${t['label'] ?? t['id']}',
                                            style: sansStyle(
                                              c,
                                              size: 13.2,
                                              weight: FontWeight.w600,
                                              color: c.ink,
                                            ),
                                          ),
                                          PrismPill(
                                            text: t['installed'] == true
                                                ? '已检测到'
                                                : '可新建配置',
                                            mono: false,
                                            fg: t['installed'] == true
                                                ? c.sage
                                                : c.muted,
                                            bg: t['installed'] == true
                                                ? c.sageBg
                                                : c.paper3,
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${t['config_path'] ?? ''}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: monoStyle(
                                          c,
                                          size: 10.8,
                                          color: c.meta,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                PrismButton(
                                  label: _applyingId == t['id']
                                      ? '写入中...'
                                      : '一键写入',
                                  compact: true,
                                  loading: _applyingId == t['id'],
                                  variant: t['installed'] == true
                                      ? PrismBtnVariant.clay
                                      : PrismBtnVariant.neutral,
                                  onPressed: _applyingId != null
                                      ? null
                                      : () => _applyTarget(t),
                                ),
                              ],
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
    );
  }
}

/// Encrypted / Sanitized Config Snapshot Export & Restore Dialog.
class ConfigSnapshotDialog extends StatefulWidget {
  final ConsoleBackend backend;
  final Future<void> Function() onRestored;
  final ValueChanged<String> onToast;

  const ConfigSnapshotDialog({
    super.key,
    required this.backend,
    required this.onRestored,
    required this.onToast,
  });

  @override
  State<ConfigSnapshotDialog> createState() => _ConfigSnapshotDialogState();
}

class _ConfigSnapshotDialogState extends State<ConfigSnapshotDialog> {
  bool _importMode = false;
  bool _includeSecrets = false;
  bool _busy = false;
  final _pwdCtrl = TextEditingController();
  final _jsonCtrl = TextEditingController();

  @override
  void dispose() {
    _pwdCtrl.dispose();
    _jsonCtrl.dispose();
    super.dispose();
  }

  Future<void> _runExport() async {
    setState(() => _busy = true);
    try {
      final res = await widget.backend.exportConfigSnapshot(
        includeSecrets: _includeSecrets,
        password: _pwdCtrl.text.trim().isEmpty ? null : _pwdCtrl.text.trim(),
      );
      if (res['ok'] == true && res['snapshot'] != null) {
        final pretty =
            const JsonEncoder.withIndent('  ').convert(res['snapshot']);
        setState(() => _jsonCtrl.text = pretty);
        await Clipboard.setData(ClipboardData(text: pretty));
        widget.onToast('已生成配置快照并复制到剪贴板');
      } else {
        widget.onToast('导出失败：${res['error'] ?? ''}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runImport() async {
    if (_jsonCtrl.text.trim().isEmpty) {
      widget.onToast('请先粘贴配置快照 JSON');
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await widget.backend.importConfigSnapshot(
        rawJson: _jsonCtrl.text.trim(),
        password: _pwdCtrl.text.trim().isEmpty ? null : _pwdCtrl.text.trim(),
      );
      if (res['ok'] == true) {
        await widget.onRestored();
        widget.onToast('配置快照已恢复并热加载生效');
        if (mounted) Navigator.of(context).pop();
      } else {
        widget.onToast('恢复失败：${res['error'] ?? ''}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    return Dialog(
      backgroundColor: c.paper,
      elevation: 0,
      shape: prismSuperellipse(
        28,
        side: BorderSide(color: c.hairline.withValues(alpha: 0.72)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 650),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const PrismSparkIcon(size: 18),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      '配置快照备份与迁移',
                      style: serifTitleStyle(c, size: 18),
                    ),
                  ),
                  PrismSegmented<bool>(
                    value: _importMode,
                    items: const [(false, '导出备份'), (true, '导入恢复')],
                    onChanged: (v) => setState(() => _importMode = v),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (!_importMode)
                PrismCheckToggle(
                  value: _includeSecrets,
                  label: '包含完整密钥与子 MCP 凭证（建议同时设置下方加密口令）',
                  onChanged: (v) => setState(() => _includeSecrets = v),
                ),
              const SizedBox(height: 8),
              PrismPasswordField(
                controller: _pwdCtrl,
                hintText: _importMode
                    ? '若快照已加密，请输入解密口令（未加密留空）'
                    : '可选：设置 PBKDF2-SHA256 加密口令（留空输出明文 JSON）',
              ),
              const SizedBox(height: 10),
              Flexible(
                child: TextField(
                  controller: _jsonCtrl,
                  maxLines: 10,
                  readOnly: !_importMode && _jsonCtrl.text.isNotEmpty,
                  style: monoStyle(c, size: 11.6, color: c.ink),
                  decoration: InputDecoration(
                    hintText: _importMode
                        ? '在此粘贴导出的配置快照 JSON...'
                        : '点击下方「生成并复制快照」后在此预览...',
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  PrismButton(
                    label: '关闭',
                    compact: true,
                    variant: PrismBtnVariant.ghost,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  PrismButton(
                    label: _busy
                        ? '处理中...'
                        : (_importMode ? '立即验证并恢复' : '生成并复制快照'),
                    compact: true,
                    loading: _busy,
                    variant: PrismBtnVariant.clay,
                    leading: Icon(
                      _importMode
                          ? Icons.restore_rounded
                          : Icons.content_copy_rounded,
                    ),
                    onPressed: _busy
                        ? null
                        : (_importMode ? _runImport : _runExport),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
