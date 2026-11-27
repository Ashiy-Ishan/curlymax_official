import 'package:flutter/material.dart';

class UserGuide extends StatelessWidget {
  const UserGuide({super.key, required this.onDone});
  final VoidCallback onDone;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Your quick start')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'Make room for your next idea.',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 20),
              const _GuideStep(
                Icons.switch_account_outlined,
                '1. Pick your channel',
                'Tap the channel icon at the top. Newly added channels appear automatically.',
              ),
              const _GuideStep(
                Icons.manage_search,
                '2. Find something to learn',
                'Explore playlists in Learn or search videos, playlists and quizzes. Choose your channel or search them all.',
              ),
              const _GuideStep(
                Icons.edit_note,
                '3. Keep what matters',
                'Sign in to save private notes across devices. Write freely, add checklist items and watch the save status.',
              ),
              const _GuideStep(
                Icons.quiz_outlined,
                '4. Try a quiz',
                'Open a video’s Quiz tab to test yourself, read feedback and try again.',
              ),
              const _GuideStep(
                Icons.notifications_outlined,
                '5. Choose your alerts',
                'Allow notifications for new videos and quizzes. You can change this in Settings at any time.',
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: onDone,
                child: const Text('Start exploring'),
              ),
              const SizedBox(height: 12),
              const Text(
                'You can reopen this guide from Settings.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _GuideStep extends StatelessWidget {
  const _GuideStep(this.icon, this.title, this.body);
  final IconData icon;
  final String title, body;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(body),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
