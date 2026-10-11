/// AI 服务、GitHub 集成、Token 优化和聊天体验；密钥只进入保险库。
library;

import 'dart:async';
import 'package:flutter/material.dart';
import '../i18n/og_l_i18n.dart';
import '../surface_bridge.dart';
import '../types.dart';

String aiText(String key, [Map<String, String>? args]) =>
    OgLI18n.instance.t('ai', key, args: args);
String aiError(Object error) {
  if (error is AiException) {
    return aiText(error.code);
  }
  final text = '$error';
  if (text.contains('401')) {
    return aiText('unauthorized');
  }
  if (text.contains('403')) {
    return aiText('forbidden');
  }
  if (text.contains('404')) {
    return aiText('notFound');
  }
  if (text.contains('RateLimit') || text.contains('429')) {
    return aiText('rateLimit');
  }
  return aiText('requestFailed');
}

class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({required this.surface, super.key});
  final SurfaceBridge surface;
  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  final _url = TextEditingController(),
      _key = TextEditingController(),
      _model = TextEditingController();
  Map<String, Object?> _draft = const AiSettings().toJson();
  bool _loading = true, _busy = false, _savedKey = false;
  String? _error;
  List<String> _models = [];
  Map<String, dynamic> _caps = {};
  Timer? _saveTimer;
  static const _presets = {
    'deepseek': ('openai', 'https://api.deepseek.com'),
    'openai': ('openai', 'https://api.openai.com/v1'),
    'anthropic': ('anthropic', 'https://api.anthropic.com/v1'),
    'gemini': ('gemini', 'https://generativelanguage.googleapis.com/v1beta')
  };
  AiSettings get _config => AiSettings.fromJson({
        ..._draft,
        'baseUrl': _url.text.trim().replaceAll(RegExp(r'/+$'), ''),
        'model': _model.text.trim()
      });
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await widget.surface.aiSettings();
      final saved = await widget.surface.aiHasKey(config: value);
      final caps = await widget.surface.aiCapabilities(value);
      if (mounted) {
        setState(() {
          _draft = value.toJson();
          _url.text = value.baseUrl;
          _model.text = value.model;
          _savedKey = saved;
          _caps = caps;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = aiError(e);
        });
      }
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _url.dispose();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  void _change(String key, Object? value) {
    setState(() => _draft[key] = value);
    _schedule();
  }

  void _schedule() {
    _saveTimer?.cancel();
    _saveTimer =
        Timer(const Duration(milliseconds: 700), () => _save(silent: true));
  }

  Future<void> _save({bool clear = false, bool silent = false}) async {
    if (_loading || _busy) {
      return;
    }
    try {
      final config = _config;
      await widget.surface.aiSaveSettings(config,
          key: silent || clear ? null : _key.text, clearKey: clear);
      if (!silent) {
        _key.clear();
      }
      final saved = await widget.surface.aiHasKey(config: config);
      if (mounted) {
        setState(() => _savedKey = saved);
        if (!silent) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(aiText('saved'))));
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = aiError(e));
      }
    }
  }

  Future<void> _detect({bool capabilities = false}) async {
    _saveTimer?.cancel();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (capabilities) {
        final caps =
            await widget.surface.aiDetectCapabilities(_config, key: _key.text);
        if (mounted) {
          setState(() {
            _caps = caps;
            if (caps['text'] == true) {
              _draft['tools'] = caps['tools'] == true;
              _draft['streaming'] = caps['streaming'] == true;
            }
          });
        }
      } else {
        final models = await widget.surface
            .aiDetectModels(key: _key.text, config: _config);
        if (mounted) {
          setState(() {
            _models = models;
            if (_model.text.isEmpty) {
              _model.text = models.first;
            }
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = aiError(e));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _save(silent: true);
      }
    }
  }

  Widget _section(String key, List<Widget> children) => Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(aiText(key), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            ...children
          ])));
  Widget _switch(String key, {String? label}) => SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(aiText(label ?? key)),
      value: _draft[key] == true,
      onChanged: _busy ? null : (v) => _change(key, v));
  Widget _select(String key, List<String> values, {String? label}) =>
      DropdownButtonFormField<String>(
          key: ValueKey('$key:${_draft[key]}'),
          initialValue: '${_draft[key]}',
          isExpanded: true,
          decoration: InputDecoration(labelText: aiText(label ?? key)),
          items: values
              .map((e) =>
                  DropdownMenuItem(value: e, child: Text(aiText('${key}_$e'))))
              .toList(),
          onChanged: _busy ? null : (v) => _change(key, v));
  Widget _number(String key, {bool decimal = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextFormField(
          initialValue: '${_draft[key]}',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: aiText(key)),
          onChanged: (v) {
            final number = decimal ? double.tryParse(v) : int.tryParse(v);
            if (number != null && number >= 0) {
              _draft[key] = number;
              _schedule();
            }
          }));
  @override
  Widget build(BuildContext context) => Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(title: Text(aiText('settings'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView(padding: const EdgeInsets.all(16), children: [
                    _switch('enabled'),
                    Text(aiText('privacy')),
                    const SizedBox(height: 16),
                    _section('provider', [
                      Wrap(spacing: 8, children: [
                        for (final preset in _presets.entries)
                          ActionChip(
                              label: Text(aiText(preset.key)),
                              onPressed: _busy
                                  ? null
                                  : () {
                                      setState(() {
                                        _draft['kind'] = preset.value.$1;
                                        _url.text = preset.value.$2;
                                        _model.clear();
                                        _models = [];
                                        _caps = {};
                                        _key.clear();
                                        _savedKey = false;
                                      });
                                      _schedule();
                                    })
                      ]),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                          key: ValueKey(_draft['kind']),
                          initialValue: '${_draft['kind']}',
                          isExpanded: true,
                          decoration:
                              InputDecoration(labelText: aiText('protocol')),
                          items: ['openai', 'anthropic', 'gemini']
                              .map((e) => DropdownMenuItem(
                                  value: e, child: Text(aiText(e))))
                              .toList(),
                          onChanged: _busy ? null : (v) => _change('kind', v)),
                      TextField(
                          controller: _url,
                          enabled: !_busy,
                          decoration: InputDecoration(
                              labelText: aiText('baseUrl'),
                              helperText: aiText('urlHint'),
                              helperMaxLines: 3),
                          onChanged: (_) => _schedule()),
                      TextField(
                          controller: _key,
                          enabled: !_busy,
                          obscureText: true,
                          enableSuggestions: false,
                          autocorrect: false,
                          decoration: InputDecoration(
                              labelText: aiText('apiKey'),
                              helperText:
                                  aiText(_savedKey ? 'keySaved' : 'keyHint'))),
                      TextField(
                          controller: _model,
                          enabled: !_busy,
                          decoration: InputDecoration(
                              labelText: aiText('model'),
                              helperText: aiText('manualModel')),
                          onChanged: (_) => _schedule()),
                      if (_models.isNotEmpty)
                        DropdownButtonFormField<String>(
                            isExpanded: true,
                            decoration: InputDecoration(
                                labelText: aiText('detectModels')),
                            items: _models
                                .map((e) => DropdownMenuItem(
                                    value: e,
                                    child: Text(e,
                                        overflow: TextOverflow.ellipsis)))
                                .toList(),
                            onChanged: (v) {
                              _model.text = v!;
                              _schedule();
                            }),
                      const SizedBox(height: 12),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        OutlinedButton.icon(
                            onPressed: _busy ? null : () => _detect(),
                            icon: const Icon(Icons.manage_search),
                            label: Text(aiText('detectModels'))),
                        OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _detect(capabilities: true),
                            icon: const Icon(Icons.science_outlined),
                            label: Text(aiText('detectCapabilities')))
                      ]),
                      Text(aiText('probeHint')),
                      if (_caps.isNotEmpty)
                        Text(
                            '${aiText('capabilities')}: ${_caps.entries.map((e) => '${e.key}: ${e.value is bool ? (e.value == true ? aiText('supported') : aiText('unsupported')) : e.key.endsWith('Error') ? aiText('${e.value}') : e.value}').join(' · ')}'),
                      _switch('tools'),
                      _switch('streaming'),
                      _switch('structured'),
                      _select('outputParameter', [
                        'auto',
                        'max_tokens',
                        'max_completion_tokens',
                        'none'
                      ]),
                      _select('reasoningEffort', ['', 'low', 'medium', 'high']),
                    ]),
                    _section('githubIntegration', [
                      ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.person_outline),
                          title: Text(
                              widget.surface.domain.session.account?.login ??
                                  aiText('loginRequired')),
                          subtitle: Text(aiText('accountContext'))),
                      TextFormField(
                          initialValue: '${_draft['defaultRepo']}',
                          decoration:
                              InputDecoration(labelText: aiText('defaultRepo')),
                          onChanged: (v) {
                            _draft['defaultRepo'] = v.trim();
                            _schedule();
                          }),
                      _switch('autoRepository'),
                      _select('toolMode', ['all', 'read', 'chat']),
                      Text(aiText('writeConfirmation')),
                    ]),
                    _section('tokenOptimization', [
                      _switch('optimize'),
                      _select(
                          'optimization', ['economy', 'balanced', 'quality']),
                      _switch('autoSummary'),
                      _switch('cache'),
                      _number('contextTokens'),
                      _number('taskBudget'),
                      _number('outputTokens'),
                      _number('inputPrice', decimal: true),
                      _number('outputPrice', decimal: true),
                      Text(aiText('priceHint')),
                      FutureBuilder<Map<String, dynamic>>(
                          future: widget.surface.aiUsageStats(),
                          builder: (context, snapshot) {
                            final usage = snapshot.data ?? {};
                            return Text(
                                '${aiText('total')}: ${usage['input'] ?? 0} / ${usage['output'] ?? 0} · ${aiText('cached')}: ${usage['cached'] ?? 0} · ${aiText('cost')}: ${((usage['cost'] as num?) ?? 0).toStringAsFixed(6)}${usage['estimated'] == true ? ' (${aiText('estimated')})' : ''}');
                          }),
                    ]),
                    _section('chatExperience', [
                      _switch('autoScroll'),
                      _number('fontSize', decimal: true),
                      Text(aiText('themeHint'))
                    ]),
                    if (_busy) const LinearProgressIndicator(),
                    if (_error != null)
                      Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(_error!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error))),
                    FilledButton.icon(
                        onPressed: _busy ? null : () => _save(),
                        icon: const Icon(Icons.save_outlined),
                        label: Text(aiText('save'))),
                    if (_savedKey)
                      TextButton(
                          onPressed: _busy ? null : () => _save(clear: true),
                          child: Text(aiText('removeKey'))),
                  ]))));
}
