import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'store.dart';

Color _accent(BuildContext context) => Theme.of(context).colorScheme.primary;
bool _reduceMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context) ||
    MediaQuery.accessibleNavigationOf(context);

/// Sequential MCQ feedback. All awards and correctness come from server receipts.
class QuizScreen extends StatefulWidget {
  const QuizScreen({super.key, required this.store, required this.quiz});
  final Store store;
  final RecordData quiz;
  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> {
  late Future<RecordData> run;
  int index = 0, points = 0;
  int? pendingChoice;
  RecordData? receipt;
  bool sending = false, completed = false;
  String? error;
  @override
  void initState() {
    super.initState();
    run = widget.store.startQuizRun(widget.quiz['id']);
  }

  void restart() => setState(() {
    run = widget.store.startQuizRun(widget.quiz['id']);
    index = 0;
    points = 0;
    pendingChoice = null;
    receipt = null;
    completed = false;
    error = null;
  });
  Future<void> answer(String runId, RecordData q, int choice) async {
    if (sending || receipt != null) return;
    setState(() {
      sending = true;
      pendingChoice = choice;
      error = null;
    });
    try {
      final feedback = await widget.store.answerQuizQuestion(
        runId,
        q['id'],
        choice,
      );
      if (!mounted) return;
      setState(() {
        receipt = feedback;
        points = feedback['points'] as int;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Could not confirm this answer. Check your connection and retry. Your choice is kept; a retry will not award points twice.',
        );
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('A little knowledge check')),
    body: FutureBuilder<RecordData>(
      future: run,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Quiz could not be loaded. Check your connection and sign-in, then try again.',
                  ),
                  TextButton(
                    onPressed: restart,
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          );
        }
        final session = snapshot.data!;
        final rows = List<RecordData>.from(session['questions']);
        if (rows.isEmpty) {
          return const Center(
            child: Text('There are no questions to answer yet.'),
          );
        }
        if (completed) {
          return QuizCompletion(receipt: receipt!, onRetry: restart);
        }
        final q = rows[index];
        final options = List<String>.from(q['options']);
        final feedback = receipt;
        final correct = feedback?['correct'] == true;
        final reduce = _reduceMotion(context);
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'TAKE YOUR TIME',
              style: TextStyle(
                color: _accent(context),
                letterSpacing: 2,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              widget.quiz['title'],
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 16,
              children: [
                Text(
                  '${index + (feedback == null ? 0 : 1)} of ${rows.length} answered',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                Stack(
                  alignment: Alignment.topRight,
                  clipBehavior: Clip.none,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 32),
                      child: PointsCounter(points: points),
                    ),
                    if (feedback != null && correct)
                      Positioned(
                        right: 16,
                        bottom: 0,
                        child: FloatingAward(
                          key: ValueKey(q['id']),
                          text: '+${feedback['awarded']}',
                          reduced: reduce,
                        ),
                      ),
                  ],
                ),
              ],
            ),
            Card(
              margin: const EdgeInsets.only(bottom: 16),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        '${index + 1}. ${q['prompt']}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...options.asMap().entries.map((o) {
                      final chosen =
                          (feedback?['choice'] ?? pendingChoice) == o.key;
                      final right =
                          feedback != null &&
                          feedback['correct_index'] == o.key;
                      final wrong = feedback != null && chosen && !correct;
                      return AnswerCard(
                        key: ValueKey('${q['id']}-${o.key}'),
                        text: o.value,
                        selected: chosen,
                        correct: right,
                        wrong: wrong,
                        onTap:
                            sending || feedback != null || pendingChoice != null
                            ? null
                            : () => answer(session['run_id'], q, o.key),
                      );
                    }),
                    if (sending)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Semantics(
                          liveRegion: true,
                          child: const Text('Checking your answer…'),
                        ),
                      ),
                    if (error != null) ...[
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          error!,
                          style: const TextStyle(color: Colors.orangeAccent),
                        ),
                      ),
                      TextButton(
                        onPressed: sending
                            ? null
                            : () =>
                                  answer(session['run_id'], q, pendingChoice!),
                        child: const Text('Retry answer'),
                      ),
                    ],
                    ExplanationPanel(
                      key: ValueKey(q['id']),
                      feedback: feedback,
                      correctOption: feedback == null
                          ? ''
                          : options[feedback['correct_index'] as int],
                    ),
                  ],
                ),
              ),
            ),
            if (feedback != null && (feedback['bonus'] as int) > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Semantics(
                  liveRegion: true,
                  child: Chip(
                    avatar: const ExcludeSemantics(
                      child: Icon(
                        Icons.local_fire_department,
                        color: Colors.orangeAccent,
                      ),
                    ),
                    label: Text(
                      '${feedback['streak']} in a row! +${feedback['bonus']} bonus.',
                    ),
                  ),
                ),
              ),
            if (feedback != null)
              FilledButton(
                onPressed: () {
                  if (feedback['complete'] == true) {
                    setState(() => completed = true);
                  } else {
                    setState(() {
                      index++;
                      receipt = null;
                      pendingChoice = null;
                      error = null;
                    });
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    feedback['complete'] == true
                        ? 'See results'
                        : 'Next question',
                  ),
                ),
              ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: sending ? null : restart,
              child: const Text('Start again'),
            ),
          ],
        );
      },
    ),
  );
}

class PointsCounter extends StatelessWidget {
  const PointsCounter({super.key, required this.points});
  final int points;
  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: 'Score: $points points',
    child: ExcludeSemantics(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: points.toDouble()),
        duration: _reduceMotion(context)
            ? Duration.zero
            : const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
        builder: (_, value, _) => Text(
          '${value.round()} pts',
          style: TextStyle(
            color: _accent(context),
            fontSize: 24,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    ),
  );
}

class FloatingAward extends StatelessWidget {
  const FloatingAward({super.key, required this.text, required this.reduced});
  final String text;
  final bool reduced;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: IgnorePointer(
      child: reduced
          ? Text(text, style: TextStyle(color: _accent(context)))
          : TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 450),
              builder: (_, t, child) => Opacity(
                opacity: 1 - t,
                child: Transform.translate(
                  offset: Offset(0, -30 * t),
                  child: child,
                ),
              ),
              child: Text(
                text,
                style: TextStyle(
                  color: _accent(context),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
    ),
  );
}

class AnswerCard extends StatefulWidget {
  const AnswerCard({
    super.key,
    required this.text,
    required this.selected,
    required this.correct,
    required this.wrong,
    this.onTap,
  });
  final String text;
  final bool selected, correct, wrong;
  final VoidCallback? onTap;
  @override
  State<AnswerCard> createState() => _AnswerCardState();
}

class _AnswerCardState extends State<AnswerCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  bool get reduce => _reduceMotion(context);
  @override
  void didUpdateWidget(covariant AnswerCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((!oldWidget.correct && widget.correct) ||
        (!oldWidget.wrong && widget.wrong)) {
      if (reduce) {
        animation.value = 1;
      } else {
        animation.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.correct
        ? _accent(context)
        : widget.wrong
        ? Colors.orangeAccent
        : widget.selected
        ? _accent(context)
        : Theme.of(context).colorScheme.outlineVariant;
    return AnimatedBuilder(
      animation: animation,
      builder: (_, _) {
        final t = reduce ? 1.0 : animation.value;
        final pop = widget.correct && !reduce
            ? 1 + .025 * math.sin(math.pi * t)
            : 1.0;
        final shake = widget.wrong && !reduce
            ? 5 * math.sin(6 * math.pi * t) * (1 - t)
            : 0.0;
        return Transform.translate(
          offset: Offset(shake, 0),
          child: Transform.scale(
            scale: pop,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Semantics(
                selected: widget.selected,
                label:
                    '${widget.text}${widget.correct
                        ? ', correct answer'
                        : widget.wrong
                        ? ', incorrect answer'
                        : ''}',
                button: true,
                enabled: widget.onTap != null,
                onTap: widget.onTap,
                child: ExcludeSemantics(
                  child: OutlinedButton(
                    onPressed: widget.onTap,
                    style: OutlinedButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.all(16),
                      disabledForegroundColor: Theme.of(
                        context,
                      ).colorScheme.onSurface,
                      side: BorderSide(
                        color: color,
                        width: widget.correct || widget.wrong ? 2 : 1,
                      ),
                      backgroundColor: widget.selected || widget.correct
                          ? color.withValues(alpha: .12)
                          : null,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (widget.correct)
                              SizedBox(
                                width: 22,
                                height: 22,
                                child: CustomPaint(
                                  painter: _CheckPainter(t, _accent(context)),
                                ),
                              )
                            else
                              Icon(
                                widget.wrong
                                    ? Icons.close
                                    : widget.selected
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_off,
                                size: 22,
                                color: color,
                              ),
                            const SizedBox(width: 12),
                            Expanded(child: Text(widget.text)),
                          ],
                        ),
                        if (widget.correct || widget.wrong)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              widget.correct ? 'Correct' : 'Incorrect',
                              style: TextStyle(color: color),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CheckPainter extends CustomPainter {
  _CheckPainter(this.progress, this.color);
  final double progress;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * .12, size.height * .52)
      ..lineTo(size.width * .4, size.height * .8)
      ..lineTo(size.width * .9, size.height * .2);
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * progress),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) =>
      old.progress != progress || old.color != color;
}

class ExplanationPanel extends StatelessWidget {
  const ExplanationPanel({
    super.key,
    required this.feedback,
    required this.correctOption,
  });
  final RecordData? feedback;
  final String correctOption;
  @override
  Widget build(BuildContext context) {
    final f = feedback;
    final Widget content = f == null
        ? const SizedBox(width: double.infinity)
        : Semantics(
            container: true,
            liveRegion: true,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.only(top: 8),
              decoration: BoxDecoration(
                color: _accent(context).withValues(alpha: .07),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    f['correct'] == true
                        ? 'Correct! +${f['awarded']} points.'
                        : 'Incorrect. Correct answer: $correctOption.',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Why this answer?',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text('${f['explanation']}'),
                ],
              ),
            ),
          );
    if (_reduceMotion(context)) return content;
    return AnimatedSize(
      duration: const Duration(milliseconds: 280),
      alignment: Alignment.topCenter,
      curve: Curves.easeOutCubic,
      child: f == null
          ? content
          : TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 280),
              builder: (_, t, child) => Transform.translate(
                offset: Offset(0, 10 * (1 - t)),
                child: child,
              ),
              child: content,
            ),
    );
  }
}

class QuizCompletion extends StatelessWidget {
  const QuizCompletion({
    super.key,
    required this.receipt,
    required this.onRetry,
  });
  final RecordData receipt;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome, size: 64, color: _accent(context)),
              const SizedBox(height: 24),
              Text(
                'CURIOSITY LOOKS GOOD ON YOU',
                style: TextStyle(color: _accent(context), letterSpacing: 2),
              ),
              const SizedBox(height: 20),
              Semantics(
                liveRegion: true,
                label:
                    'Quiz complete. ${receipt['score']} of ${receipt['total']} correct.',
                child: ExcludeSemantics(
                  child: Text(
                    '${receipt['score']} / ${receipt['total']}',
                    style: const TextStyle(
                      fontSize: 64,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              PointsCounter(points: receipt['points']),
              const SizedBox(height: 12),
              const Text(
                'Your score and points are saved. Keep exploring, keep learning.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.replay),
                label: const Text('Try again'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Back to video'),
              ),
            ],
          ),
        ),
      ),
      if (!_reduceMotion(context))
        Positioned.fill(
          child: ExcludeSemantics(
            child: IgnorePointer(
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 500),
                builder: (_, t, _) =>
                    CustomPaint(painter: _ConfettiPainter(t, _accent(context))),
              ),
            ),
          ),
        ),
    ],
  );
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.t, this.accent);
  final double t;
  final Color accent;
  @override
  void paint(Canvas canvas, Size size) {
    if (t >= 1) return;
    final colors = [accent, Colors.orangeAccent, Colors.lightBlueAccent];
    for (var i = 0; i < 24; i++) {
      final angle = math.pi * (i / 23);
      final x = size.width / 2 + math.cos(angle) * t * size.width * .45;
      final y = size.height * .2 - math.sin(angle) * t * 120 + 230 * t * t;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate((i % 5 + 1) * t * 2);
      canvas.drawRect(
        const Rect.fromLTWH(-3, -5, 6, 10),
        Paint()..color = colors[i % 3].withValues(alpha: 1 - t),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) =>
      old.t != t || old.accent != accent;
}
