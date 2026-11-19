import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'config.dart';

/// Bundled policy remains readable without a browser or network connection.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  static const sections = <(String, String)>[
    (
      'Information we process',
      'You can browse public videos without an account. Signing in processes your email, account ID and authentication information. Private notes, quiz answers, scores, points and attempt timestamps support synchronized notes and server grading. Signed-in notification read status can synchronize across devices. Public YouTube channel, playlist, video and engagement information maintains the catalog.',
    ),
    (
      'Notifications and service providers',
      'Opt-in push notifications use Firebase Cloud Messaging device registration identifiers. Supabase provides authentication, database storage and backend services. Google provides Google sign-in, YouTube playback and metadata, and Firebase messaging. Providers may process connection, device and security logs. YouTube embeds may process cookies, device information and playback activity under Google’s privacy policy and may show ads. CURLYmax does not run its own advertising system.',
    ),
    (
      'How information is used',
      'Account information authenticates you, synchronizes private content, prevents abuse and supports deletion requests. We do not sell your private notes or quiz history. Provider processing is governed by their policies, including policies.google.com/privacy and supabase.com/privacy.',
    ),
    (
      'Storage and security',
      'The app uses HTTPS. Database permissions restrict private notes and quiz history to their account. Public catalog content and settings may be cached locally. A sign-in session is stored on your device so you can return to your account. No system can guarantee absolute security.',
    ),
    (
      'Retention and account deletion',
      'Account information, notes and quiz history remain while your account is active unless deleted. Settings → Your account → Clear all my data deletes your sign-in account and associated private notes, quiz attempts, points, in-progress quiz records and read receipts from active storage. Recent sign-in and confirmation are required. Shared public videos, playlists, quizzes and other users’ data remain. Uninstalling alone does not delete server data. Provider backups and security logs may persist under provider retention settings or applicable requirements.',
    ),
    (
      'Your choices and support',
      'Browse as a guest, edit or delete notes, and disable notifications in the app or Android settings. You can request account deletion by email even without the app. We verify account ownership before processing requests. Never send passwords, verification codes or private keys. Material policy updates will appear here with an updated effective date.',
    ),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Privacy policy')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Privacy at CURLYmax',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 12),
        const SelectableText(
          'Effective date: 19 November 2026\nDeveloper: Ashinshana Ishan | curlymax',
        ),
        const SizedBox(height: 8),
        const SelectableText(AppConfig.supportEmail),
        for (final section in sections) ...[
          const SizedBox(height: 24),
          Text(section.$1, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          SelectableText(section.$2),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: () => composeSupportEmail(context, deletion: true),
          icon: const Icon(Icons.email_outlined),
          label: const Text('Request account deletion by email'),
        ),
      ],
    ),
  );
}

Future<void> composeSupportEmail(
  BuildContext context, {
  bool deletion = false,
}) async {
  // Encode query values without form-style '+' substitution in mail clients.
  final subject = deletion
      ? 'CURLYmax account deletion request'
      : 'CURLYmax support';
  final body = deletion
      ? 'Please delete my CURLYmax account and associated private data.\n\nAccount email: \n\nI understand ownership verification is required. I will not send passwords or verification codes.'
      : 'Please describe the issue here:\n';
  final uri = Uri.parse(
    'mailto:${AppConfig.supportEmail}?subject=${Uri.encodeComponent(subject)}&body=${Uri.encodeComponent(body)}',
  );
  try {
    if (await launchUrl(uri)) return;
  } catch (_) {
    // Devices without an email app still provide a usable contact address.
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Email support'),
      content: SelectableText(
        'Email ${AppConfig.supportEmail}\n\nSubject: $subject\n\nSend from your account email. Never include passwords or verification codes.',
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(
              const ClipboardData(text: AppConfig.supportEmail),
            );
            if (dialogContext.mounted) Navigator.pop(dialogContext);
          },
          child: const Text('Copy email address'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
