import 'dart:async';
import 'package:flutter/material.dart';
import 'store.dart';

class NotificationInbox extends StatefulWidget {
  const NotificationInbox({
    super.key,
    required this.store,
    required this.onOpen,
  });
  final Store store;
  final void Function(RecordData) onOpen;
  @override
  State<NotificationInbox> createState() => _NotificationInboxState();
}

class _NotificationInboxState extends State<NotificationInbox> {
  final rows = <RecordData>[];
  final read = <String>{};
  bool loading = false, more = true;
  String? error;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    unawaited(load(reset: true));
  }

  Future<void> load({bool reset = false}) async {
    if (loading && !reset) return;
    final request = ++generation;
    final identity = widget.store.db.auth.currentUser?.id;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final offset = reset ? 0 : rows.length;
      final page = List<RecordData>.from(
        await widget.store.db
            .from('notifications')
            .select()
            .order('created_at', ascending: false)
            .order('id')
            .range(offset, offset + 49)
            .timeout(const Duration(seconds: 20)),
      );
      var receipts = <RecordData>[];
      if (identity != null && page.isNotEmpty) {
        receipts = List<RecordData>.from(
          await widget.store.db
              .from('notification_reads')
              .select('notification_id')
              .eq('user_id', identity)
              .inFilter(
                'notification_id',
                page.map((row) => row['id']).toList(),
              )
              .timeout(const Duration(seconds: 20)),
        );
      }
      if (!mounted ||
          request != generation ||
          widget.store.db.auth.currentUser?.id != identity) {
        return;
      }
      setState(() {
        if (reset) {
          rows.clear();
          read.clear();
        }
        final known = rows.map((row) => row['id']).toSet();
        rows.addAll(page.where((row) => !known.contains(row['id'])));
        read.addAll(receipts.map((row) => row['notification_id'] as String));
        more = page.length == 50;
      });
    } catch (_) {
      if (mounted && request == generation) {
        setState(
          () => error =
              'Updates could not load. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted && request == generation) setState(() => loading = false);
    }
  }

  Future<void> markRead(String id) async {
    if (!widget.store.signedIn) return;
    try {
      await widget.store.markNotificationRead(id);
    } catch (_) {
      // A failed receipt never blocks opening public content. It stays unread
      // on the next refresh and may be retried by opening the item again.
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Notifications')),
    body: RefreshIndicator(
      onRefresh: () => load(reset: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Published videos and quizzes. Push alerts are optional in Settings.',
          ),
          if (!widget.store.signedIn)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Sign in to synchronize read status across your devices.',
              ),
            ),
          if (loading)
            const LinearProgressIndicator(
              semanticsLabel: 'Loading notifications',
            ),
          if (error != null) ...[
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            TextButton(
              onPressed: () => load(reset: rows.isEmpty),
              child: const Text('Retry'),
            ),
          ],
          if (!loading && error == null && rows.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No published updates yet.'),
            ),
          for (final row in rows)
            Card(
              child: ListTile(
                leading: Icon(
                  row['kind'] == 'quiz'
                      ? Icons.quiz_outlined
                      : Icons.play_circle_outline,
                ),
                title: Text(row['title'] ?? 'CURLYmax update'),
                subtitle: Text(
                  '${row['kind'] == 'quiz' ? 'Quiz' : 'Video'} · ${row['created_at'].toString().split('T').first}',
                ),
                trailing: widget.store.signedIn && !read.contains(row['id'])
                    ? const Text('Unread')
                    : null,
                onTap: () {
                  unawaited(markRead(row['id']));
                  Navigator.pop(context);
                  widget.onOpen({
                    'kind': row['kind'],
                    'item_id': row['item_id'],
                    'event_id': row['id'],
                  });
                },
              ),
            ),
          if (more && rows.isNotEmpty)
            TextButton(
              onPressed: loading ? null : load,
              child: const Text('Load more'),
            ),
        ],
      ),
    ),
  );
}
