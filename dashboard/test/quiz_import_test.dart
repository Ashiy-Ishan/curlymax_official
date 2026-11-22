import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:curlymax_dashboard/quiz_import.dart';

void main() {
  testWidgets(
    'Owner validates JSON before uploading the selected video draft',
    (tester) async {
      Map<String, dynamic>? uploaded;
      String? selectedVideo;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => QuizImportDialog(
                    videos: const [
                      {'id': 'video-1', 'title': 'Test video'},
                    ],
                    upload: (id, quiz) async {
                      selectedVideo = id;
                      uploaded = quiz;
                    },
                  ),
                ),
                child: const Text('Open import'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open import'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Upload draft'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test video').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), quizJsonExample);
      await tester.ensureVisible(find.text('Validate JSON'));
      await tester.tap(find.text('Validate JSON'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 questions validated'), findsOneWidget);
      await tester.tap(find.text('Upload draft'));
      await tester.pumpAndSettle();
      expect(selectedVideo, 'video-1');
      expect(uploaded!['questions'], hasLength(1));
      expect(find.text('Import quiz JSON'), findsNothing);
    },
  );
  test('Example normalizes a quiz with private zero-based answers', () {
    final quiz = parseQuizImport(quizJsonExample);
    expect(quiz['title'], 'Video knowledge check');
    expect(quiz['questions'][0]['correct_index'], 0);
    expect(quiz['questions'][0]['options'], hasLength(4));
  });
  test('Rejects malformed or unsupported import formats', () {
    for (final source in [
      '{',
      '[]',
      '{}',
      '{"title":"q","questions":[]}',
      '{"title":"q","questions":[],"status":"published"}',
    ]) {
      expect(() => parseQuizImport(source), throwsFormatException);
    }
  });
  test('Rejects invalid answers, options and question types before upload', () {
    for (final change in [
      {'correct_index': -1},
      {'correct_index': 4},
      {'correct_index': 0.0},
      {
        'options': ['only one'],
      },
      {
        'options': ['valid', ' '],
      },
      {
        'options': ['valid', 123],
      },
      {'prompt': ''},
      {'explanation': 42},
      {'unexpected': true},
    ]) {
      final value = jsonDecode(quizJsonExample);
      value['questions'][0].addAll(change);
      expect(() => parseQuizImport(jsonEncode(value)), throwsFormatException);
    }
  });
  test(
    'SQL-like content remains plain text and multiple questions are supported',
    () {
      final value = jsonDecode(quizJsonExample);
      value['title'] = "  Robert'); DROP TABLE quizzes;--  ";
      value['questions'].add(Map<String, dynamic>.from(value['questions'][0]));
      final result = parseQuizImport(jsonEncode(value));
      expect(result['title'], "Robert'); DROP TABLE quizzes;--");
      expect(result['questions'], hasLength(2));
    },
  );
  test('Bounds question count and input bytes', () {
    final value = jsonDecode(quizJsonExample);
    value['questions'] = List.filled(101, value['questions'][0]);
    expect(() => parseQuizImport(jsonEncode(value)), throwsFormatException);
    expect(() => parseQuizImport('x' * 262145), throwsFormatException);
  });
}
