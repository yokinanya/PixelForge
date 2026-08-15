/// Bottom sheet showing the currently selected redaction items.
library;

import 'package:flutter/material.dart';
import 'package:pixelforge/src/application/redaction_controller.dart';
import 'package:pixelforge/src/application/redaction_models.dart';
import 'package:pixelforge/src/features/redaction/redaction_panels.dart';

class RedactionSelectionList extends StatelessWidget {
  const RedactionSelectionList({super.key, required this.session});

  final RedactionController session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final visible = session.candidates
            .where(
              (candidate) =>
                  candidate.selected ||
                  candidate.kind != DetectionKind.textLine,
            )
            .toList();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: visible.isEmpty
                ? const SizedBox(
                    height: 140,
                    child: Center(child: Text('暂未选择内容')),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, index) {
                      final candidate = visible[index];
                      return CheckboxListTile(
                        value: candidate.selected,
                        onChanged: (_) => session.toggleCandidate(candidate.id),
                        title: Text(redactionCandidateLabel(candidate)),
                        subtitle: candidate.kind == DetectionKind.textLine
                            ? null
                            : candidate.text == null
                            ? null
                            : Text(candidate.text!),
                      );
                    },
                  ),
          ),
        );
      },
    );
  }
}
