import 'dart:convert';
import 'package:flutter/material.dart';

const quizJsonExample = '''{
  "title": "Video knowledge check",
  "questions": [
    {
      "prompt": "Which option is correct?",
      "options": ["Option 1", "Option 2", "Option 3", "Option 4"],
      "correct_index": 0,
      "explanation": "Explain why the first option is correct."
    }
  ]
}''';

/// Strict validation is repeated by the owner-only transactional server RPC.
Map<String, dynamic> parseQuizImport(String source) {
  if (utf8.encode(source).length > 262144) {
    throw const FormatException('JSON must be no larger than 256 KiB.');
  }
  final dynamic value;
  try {
    value = jsonDecode(source);
  } catch (_) {
    throw const FormatException(
      'Invalid JSON. Check quotes, commas and brackets.',
    );
  }
  if (value is! Map<String, dynamic> ||
      value.keys.any((k) => !['title', 'questions'].contains(k))) {
    throw const FormatException(
      'Use an object containing title and questions only.',
    );
  }
  String text(dynamic v, String label, int max) {
    if (v is! String || v.trim().isEmpty || v.trim().runes.length > max) {
      throw FormatException('$label must contain 1–$max characters.');
    }
    return v.trim();
  }

  final title = text(value['title'], 'Quiz title', 500);
  final questions = value['questions'];
  if (questions is! List || questions.isEmpty || questions.length > 100) {
    throw const FormatException('Provide 1–100 questions.');
  }
  final normalized = <Map<String, dynamic>>[];
  for (var i = 0; i < questions.length; i++) {
    final q = questions[i];
    final label = 'Question ${i + 1}';
    if (q is! Map<String, dynamic> ||
        q.keys.any(
          (k) => ![
            'prompt',
            'options',
            'correct_index',
            'explanation',
          ].contains(k),
        )) {
      throw FormatException('$label has an unsupported field or format.');
    }
    final options = q['options'];
    if (options is! List || options.length < 2 || options.length > 4) {
      throw FormatException('$label needs 2–4 options.');
    }
    final answer = q['correct_index'];
    if (answer is! int || answer < 0 || answer >= options.length) {
      throw FormatException(
        '$label: correct_index starts at 0 and must match an option.',
      );
    }
    final explanation = q['explanation'] ?? '';
    if (explanation is! String || explanation.runes.length > 5000) {
      throw FormatException(
        '$label: explanation must be text up to 5000 characters.',
      );
    }
    normalized.add({
      'prompt': text(q['prompt'], '$label prompt', 5000),
      'options': options.map((v) => text(v, '$label option', 1000)).toList(),
      'correct_index': answer,
      'explanation': explanation.trim(),
    });
  }
  return {'title': title, 'questions': normalized};
}

class QuizImportDialog extends StatefulWidget {
  const QuizImportDialog({
    super.key,
    required this.videos,
    required this.upload,
  });
  final List<Map<String, dynamic>> videos;
  final Future<void> Function(String, Map<String, dynamic>) upload;
  @override
  State<QuizImportDialog> createState() => _QuizImportDialogState();
}

class _QuizImportDialogState extends State<QuizImportDialog> {
  final controller = TextEditingController();
  String? videoId, error;
  Map<String, dynamic>? preview;
  bool uploading = false;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !uploading,
    child: AlertDialog(
      title: const Text('Import quiz JSON'),
      content: SizedBox(
        width: 650,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Choose a video, paste JSON, validate, then upload. The quiz stays a draft until you publish it. correct_index uses 0 for the first answer.',
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: videoId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Video'),
                items: widget.videos
                    .map(
                      (v) => DropdownMenuItem<String>(
                        value: v['id'] as String,
                        child: Text(
                          '${v['title']}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: uploading
                    ? null
                    : (v) => setState(() => videoId = v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                readOnly: uploading,
                minLines: 8,
                maxLines: 14,
                maxLength: 262144,
                decoration: const InputDecoration(
                  labelText: 'Quiz JSON',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {
                  preview = null;
                  error = null;
                }),
              ),
              TextButton(
                onPressed: uploading
                    ? null
                    : () => setState(() {
                        controller.text = quizJsonExample;
                        preview = null;
                        error = null;
                      }),
                child: const Text('Insert example (replaces pasted text)'),
              ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (preview != null)
                Text(
                  '${preview!['title']} · ${(preview!['questions'] as List).length} questions validated. Uploads as draft.',
                ),
              if (uploading)
                const LinearProgressIndicator(semanticsLabel: 'Uploading quiz'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: uploading ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        OutlinedButton(
          onPressed: uploading
              ? null
              : () {
                  try {
                    final result = parseQuizImport(controller.text);
                    setState(() {
                      preview = result;
                      error = null;
                    });
                  } on FormatException catch (e) {
                    setState(() {
                      preview = null;
                      error = e.message;
                    });
                  }
                },
          child: const Text('Validate JSON'),
        ),
        FilledButton(
          onPressed: uploading || preview == null || videoId == null
              ? null
              : () async {
                  setState(() {
                    uploading = true;
                    error = null;
                  });
                  try {
                    await widget.upload(videoId!, preview!);
                    if (context.mounted) Navigator.pop(context, true);
                  } catch (_) {
                    if (mounted) {
                      setState(
                        () => error =
                            'Upload could not be confirmed. Refresh the quiz list before retrying to avoid a duplicate. Check that the quiz-import migration is installed.',
                      );
                    }
                  } finally {
                    if (mounted) setState(() => uploading = false);
                  }
                },
          child: const Text('Upload draft'),
        ),
      ],
    ),
  );
}
