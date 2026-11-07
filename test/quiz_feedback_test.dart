import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:curlymax/store.dart';
import 'package:curlymax/quiz_screen.dart';

class QuizStore extends Store {
  QuizStore(super.prefs, SupabaseClient client) : super(client: client);
  int calls = 0;
  bool fail = false;
  Completer<RecordData>? answerResponse;
  final requests = <int>[];
  @override
  Future<RecordData> startQuizRun(String quiz) async => {
    'run_id': 'run',
    'questions': [
      for (var i = 0; i < 4; i++)
        {
          'id': 'q$i',
          'prompt': 'Question $i',
          'options': ['Option A', 'Option B'],
        },
    ],
  };
  @override
  Future<RecordData> answerQuizQuestion(
    String run,
    String question,
    int choice,
  ) async {
    calls++;
    requests.add(choice);
    if (fail) throw StateError('offline');
    if (answerResponse != null) return answerResponse!.future;
    final i = int.parse(question.substring(1));
    return {
      'question_id': question,
      'choice': choice,
      'correct': choice == 0,
      'correct_index': 0,
      'explanation': 'A concise explanation.',
      'awarded': choice == 0 ? 100 : 0,
      'bonus': i == 2 ? 50 : 0,
      'points': i == 3 ? 350 : (i + 1) * 100 + (i == 2 ? 50 : 0),
      'streak': choice == 0 ? i + 1 : 0,
      'score': i == 3 ? 3 : i + 1,
      'total': 4,
      'complete': i == 3,
    };
  }
}

void main() {
  late QuizStore store;
  late SupabaseClient client;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    client = SupabaseClient(
      'https://unit.test',
      'public',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    store = QuizStore(await SharedPreferences.getInstance(), client);
  });
  tearDown(() async {
    store.dispose();
    await client.dispose();
  });
  Future<void> launch(WidgetTester tester, {bool reduced = false}) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: child!,
        ),
        home: QuizScreen(
          store: store,
          quiz: const {'id': 'quiz', 'title': 'Quiz title'},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Three correct answers award milestone once; wrong option is labeled and explained',
    (tester) async {
      await launch(tester);
      for (var i = 0; i < 3; i++) {
        await tap(tester, 'Option A');
        expect(find.text('Why this answer?'), findsOneWidget);
        await tap(tester, 'Option A'); // locked answered card
        expect(store.calls, i + 1);
        if (i == 2) expect(find.text('3 in a row! +50 bonus.'), findsOneWidget);
        await tap(tester, 'Next question');
      }
      await tap(tester, 'Option B');
      expect(find.text('Incorrect'), findsOneWidget);
      expect(find.text('Correct'), findsOneWidget);
      expect(find.text('Incorrect. Correct answer: Option A.'), findsOneWidget);
      expect(find.text('350 pts'), findsOneWidget);
      await tap(tester, 'See results');
      expect(find.text('3 / 4'), findsOneWidget);
      expect(find.text('350 pts'), findsOneWidget);
      expect(store.calls, 4);
      await tap(tester, 'Try again');
      expect(find.text('0 of 4 answered'), findsOneWidget);
      expect(find.text('0 pts'), findsOneWidget);
    },
  );
  testWidgets(
    'In-flight taps are ignored and server totals are authoritative',
    (tester) async {
      await launch(tester);
      store.answerResponse = Completer<RecordData>();
      await tester.tap(find.text('Option A'));
      await tester.pump();
      await tester.tap(find.text('Option B'));
      await tester.pump();
      expect(store.calls, 1);
      store.answerResponse!.complete({
        'choice': 0,
        'correct': true,
        'correct_index': 0,
        'explanation': 'Server feedback',
        'awarded': 100,
        'bonus': 0,
        'points': 137,
        'streak': 1,
        'score': 1,
        'total': 4,
        'complete': false,
      });
      await tester
          .pump(); // navigation available before the 400ms decoration ends
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Next question'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.pumpAndSettle();
      expect(find.text('137 pts'), findsOneWidget);
    },
  );
  testWidgets(
    'Failed requests retry the same choice and reduced motion has static accessible feedback',
    (tester) async {
      final semantics = tester.ensureSemantics();

      await launch(tester, reduced: true);
      store.fail = true;
      await tap(tester, 'Option A');
      expect(find.text('Retry answer'), findsOneWidget);
      await tap(tester, 'Option B');
      expect(store.calls, 1);
      store.fail = false;
      await tap(tester, 'Retry answer');
      expect(store.requests, [0, 0]);
      expect(find.text('100 pts'), findsOneWidget);
      expect(find.bySemanticsLabel('Score: 100 points'), findsOneWidget);
      expect(find.text('Correct! +100 points.'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      semantics.dispose();
    },
  );
  testWidgets('Feedback remains readable at large text on a narrow screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: QuizScreen(
          store: store,
          quiz: const {'id': 'quiz', 'title': 'Quiz'},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tap(tester, 'Option B');
    await tester.ensureVisible(find.text('Why this answer?'));
    await tester.pumpAndSettle();
    expect(find.text('Incorrect. Correct answer: Option A.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
