import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:curlymax_dashboard/main.dart';

void main() {
  late SupabaseClient db;
  setUp(
    () => db = SupabaseClient('https://example.supabase.co', 'test-public-key'),
  );
  tearDown(() => db.dispose());
  Future<void> open(WidgetTester tester, List<RecordData> items) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuestionEditor(
            db: db,
            quiz: const {'id': 'quiz', 'title': 'Quiz', 'status': 'draft'},
            items: items,
          ),
        ),
      ),
    );
  }

  testWidgets('New questions have four options and no guessed answer', (
    tester,
  ) async {
    await open(tester, []);
    await tester.tap(find.text('Add question'));
    await tester.pump();
    expect(find.widgetWithText(TextFormField, 'Option 4'), findsOneWidget);
    expect(
      tester
          .widget<DropdownButtonFormField<int>>(
            find.byType(DropdownButtonFormField<int>),
          )
          .initialValue,
      isNull,
    );
    await tester.scrollUntilVisible(
      find.text('Add option'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Add option'))
          .onPressed,
      isNull,
    );
  });
  testWidgets('A complete prompt still requires an explicit correct answer', (
    tester,
  ) async {
    await open(tester, [
      {
        'prompt': 'Pick one',
        'options': ['A', 'B', 'C', 'D'],
        'correct_index': null,
      },
    ]);
    await tester.tap(find.text('Save questions'));
    await tester.pump();
    expect(
      find.text('Complete every prompt, option and correct answer.'),
      findsOneWidget,
    );
  });
  testWidgets(
    'Legacy six-option questions keep their answer; removing it requires reselection',
    (tester) async {
      await open(tester, [
        {
          'prompt': 'Legacy',
          'options': ['A', 'B', 'C', 'D', 'E', 'F'],
          'correct_index': 5,
        },
      ]);
      await tester.scrollUntilVisible(
        find.text('Remove last option'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.widgetWithText(TextFormField, 'Option 6'), findsOneWidget);
      expect(
        tester
            .widget<DropdownButtonFormField<int>>(
              find.byType(DropdownButtonFormField<int>),
            )
            .initialValue,
        5,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Add option'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Remove last option'));
      await tester.pump();
      expect(
        tester
            .widget<DropdownButtonFormField<int>>(
              find.byType(DropdownButtonFormField<int>),
            )
            .initialValue,
        isNull,
      );
      expect(find.widgetWithText(TextFormField, 'Option 5'), findsOneWidget);
    },
  );
}
