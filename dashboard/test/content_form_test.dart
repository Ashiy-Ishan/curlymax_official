import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:curlymax_dashboard/main.dart';

void main() {
  testWidgets(
    'One-form quiz saves a draft and safely remaps optional choices',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      RecordData? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<RecordData>(
                    context: context,
                    builder: (_) => const ContentForm(
                      table: 'quizzes',
                      data: {
                        'videos': [
                          {'id': 'v1', 'title': 'Video one'},
                        ],
                      },
                    ),
                  );
                },
                child: const Text('New quiz'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('New quiz'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Video one').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Quiz title'),
        'Which answer?',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Answer option 1'),
        'A',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Answer option 2'),
        'B',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Answer option 4 (optional)'),
        'D',
      );
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.text('Choose a non-empty correct answer'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Answer option 4').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(result?['status'], 'draft');
      expect(result?['question'], {
        'prompt': 'Which answer?',
        'options': ['A', 'B', 'D'],
        'correct_index': 2,
        'explanation': '',
      });
    },
  );

  testWidgets('Channel icons reject non-HTTPS URLs', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ContentForm(
            table: 'channels',
            row: {'name': 'CURLYmax', 'handle': '@ashiy_ish'},
            data: {},
          ),
        ),
      ),
    );
    final icon = find.widgetWithText(
      TextFormField,
      'Channel icon HTTPS URL (optional)',
    );
    await tester.enterText(icon, 'http://example.com/icon.png');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Use an HTTPS image URL'), findsOneWidget);
  });

  testWidgets(
    'Video form rejects empty input and filters sections by channel',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContentForm(
              table: 'videos',
              data: {
                'channels': [
                  {'id': 'c1', 'name': 'One'},
                  {'id': 'c2', 'name': 'Two'},
                ],
                'sections': [
                  {'id': 's1', 'channel_id': 'c1', 'name': 'First section'},
                  {'id': 's2', 'channel_id': 'c2', 'name': 'Other section'},
                ],
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.text('Required'), findsWidgets);
      await tester.tap(find.text('Channel').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('One').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Section').first);
      await tester.pumpAndSettle();
      expect(find.text('First section'), findsOneWidget);
      expect(find.text('Other section'), findsNothing);
    },
  );
  testWidgets(
    'New quizzes default to draft and explain publication prerequisites',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ContentForm(table: 'quizzes', data: {}),
          ),
        ),
      );
      expect(find.text('Publication status'), findsNothing);
      expect(find.textContaining('Saved as a draft'), findsOneWidget);
    },
  );
}
