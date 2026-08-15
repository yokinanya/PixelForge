/// Popup for selecting word-level masks from one OCR text line.
library;

import 'package:flutter/material.dart';
import 'package:pixelforge/src/application/redaction_models.dart';

Future<Set<String>?> showRedactionWordSelectionDialog({
  required BuildContext context,
  required List<DetectionCandidate> words,
}) => showDialog<Set<String>>(
  context: context,
  builder: (_) => RedactionWordSelectionDialog(words: words),
);

class RedactionWordSelectionDialog extends StatefulWidget {
  const RedactionWordSelectionDialog({super.key, required this.words});

  final List<DetectionCandidate> words;

  @override
  State<RedactionWordSelectionDialog> createState() =>
      _RedactionWordSelectionDialogState();
}

class _RedactionWordSelectionDialogState
    extends State<RedactionWordSelectionDialog> {
  late final Set<String> _selectedIds = {
    for (final word in widget.words)
      if (word.selected) word.id,
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择要打码的词'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: SingleChildScrollView(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final word in widget.words)
                FilterChip(
                  label: Text(word.text ?? ''),
                  selected: _selectedIds.contains(word.id),
                  onSelected: (selected) => setState(() {
                    if (selected) {
                      _selectedIds.add(word.id);
                    } else {
                      _selectedIds.remove(word.id);
                    }
                  }),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selectedIds),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
