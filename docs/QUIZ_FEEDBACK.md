# MCQ feedback and points

The Android quiz keeps CURLYmax's dark Material 3 cards, lime accent, typography and video navigation. Questions are now answered one at a time so correctness and explanations arrive immediately from the server.

## Enable on an existing Supabase project

Run the entire `supabase/migrations/202611060003_quiz_feedback.sql` file **once** in your existing project's SQL Editor. Do not rerun `install.sql` on the existing project. The migration preserves catalog data and previous attempts. Earlier attempts have zero points. For a fresh project, `install.sql` already includes this migration.

The dashboard's **Questions & answers** editor now includes an optional **Why this answer?** field. Save a concise explanation for each question. Explanations are stored with the private answer keys. If omitted, the server returns a short statement naming the correct option after answering. Updating an existing dashboard installation only needs the quiz-feedback migration; the updated `dashboard/supabase/001_dashboard.sql` also supports explanations for fresh dashboard installations.

Build/install the updated Android APK and restart the dashboard after the SQL upgrade. An older server produces a quiz-load error until its functions are installed.

## Rules and behavior

- A correct answer earns 100 points. A wrong answer earns zero. Each non-overlapping milestone of three consecutive correct answers gives +50 (streak 3, 6, 9, ...). A wrong answer resets the streak.
- Points are recorded for each quiz attempt. **Try again** intentionally starts a new attempt and a new score.
- The server owns correctness, streaks, points and completion. A row lock serializes answer submissions. An immutable per-question receipt makes repeat/concurrent requests idempotent, including the final answer and saved attempt. The client never calculates or uploads its own point total.
- Once a choice is submitted it cannot be changed in that run. A network failure preserves the choice and retries that same request. Next/results navigation becomes available as soon as the response arrives; decorative animation never gates it.
- Wrong answers show an explicit Incorrect label, highlight the correct option and disclose only that question's feedback. Unanswered keys and explanations remain private. Runs are restricted to their authenticated user. Question edits invalidate unfinished runs.
- The checkmark, pop and shake take 320 ms. The floating award takes 450 ms, score counter 400 ms, explanation expansion 280 ms and single confetti burst 500 ms.
- Android reduced-animation/accessibility navigation settings replace movement with static checks, feedback and totals. Confetti is omitted. Screen-reader live regions announce feedback, actual point totals and earned streak bonuses, without announcing every animated counter frame.

## Verification

Run the checks with these commands.

```sh
flutter analyze
flutter test
python3 scripts/test_quiz_feedback.py
```

The last command needs Docker and the cached `postgres:15-alpine` image. It creates an offline disposable database, applies migrations, tests direct guest/two-user permissions and server grading/duplicate submissions, then removes only its own container. It never uses hosted credentials or sends notifications.

Android acceptance still requires installing the SQL upgrade and testing the updated APK with correct/wrong answers, 3-answer streak, network retry, quiz completion/retry, large text, TalkBack and the device's reduced-animation setting. Automated widget semantics checks do not replace testing actual TalkBack announcements.
