import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:curlymax_dashboard/main.dart';

void main() {
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
      expect(find.text('draft'), findsOneWidget);
      expect(
        find.textContaining('Save a new quiz as a draft first'),
        findsOneWidget,
      );
    },
  );
}
