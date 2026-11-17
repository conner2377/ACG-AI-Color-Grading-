import 'package:flutter/material.dart';

import '../ai/ai_service.dart';

class AiSettingsDialog extends StatefulWidget {
  const AiSettingsDialog({super.key, required this.initial});
  final AiSettings initial;
  @override
  State<AiSettingsDialog> createState() => _AiSettingsDialogState();
}

class _AiSettingsDialogState extends State<AiSettingsDialog> {
  late AiProvider provider = widget.initial.provider;
  late final model = TextEditingController(text: widget.initial.model);
  late final key = TextEditingController(text: widget.initial.apiKey);
  bool obscure = true;

  Future<void> _switch(AiProvider p) async {
    final s = await AiSettings.loadFor(p);
    setState(() {
      provider = p;
      model.text = s.model;
      key.text = s.apiKey;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('AI 설정'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SegmentedButton<AiProvider>(
            segments: [for (final p in AiProvider.values) ButtonSegment(value: p, label: Text(p.label))],
            selected: {provider},
            onSelectionChanged: (s) => _switch(s.first),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: key,
            obscureText: obscure,
            decoration: InputDecoration(
              labelText: '${provider.label} API 키',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(icon: Icon(obscure ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => obscure = !obscure)),
            ),
          ),
          const SizedBox(height: 4),
          SelectableText('키 발급: ${provider.keyHelpUrl}', style: const TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 12),
          TextField(
            controller: model,
            decoration: InputDecoration(labelText: '모델 (기본: ${provider.defaultModel})', border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          const Text('키는 이 기기에만 암호화되어 저장되고, 보정 요청 시 해당 AI 회사로만 전송됩니다.',
              style: TextStyle(fontSize: 12, color: Colors.white54)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
        FilledButton(
          onPressed: () => Navigator.pop(context, AiSettings(provider: provider, model: model.text, apiKey: key.text)),
          child: const Text('저장'),
        ),
      ],
    );
  }
}
