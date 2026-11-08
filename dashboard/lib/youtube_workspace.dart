import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Owner-only RPCs enforce permission independently of this interface.
class YoutubeWorkspace extends StatefulWidget {
  final SupabaseClient db;
  final List<Map<String, dynamic>> channels, sections;
  final Future<void> Function() onChanged;
  const YoutubeWorkspace({
    super.key,
    required this.db,
    required this.channels,
    required this.sections,
    required this.onChanged,
  });
  @override
  State<YoutubeWorkspace> createState() => _YoutubeWorkspaceState();
}

class _YoutubeWorkspaceState extends State<YoutubeWorkspace> {
  List<Map<String, dynamic>> settings = [], analytics = [];
  bool busy = true;
  String? error, message;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (mounted) {
      setState(() {
        busy = true;
        error = null;
      });
    }
    try {
      final values = await Future.wait([
        widget.db.rpc('owner_youtube_settings'),
        widget.db.rpc('owner_youtube_analytics'),
      ]);
      if (mounted) {
        setState(() {
          settings = List<Map<String, dynamic>>.from(values[0]);
          analytics = List<Map<String, dynamic>>.from(values[1]);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Could not load YouTube tools. Check your connection, owner access, and the YouTube database migration.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> sync(String id) async {
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      final response = await widget.db.functions.invoke(
        'sync-youtube',
        body: {'channel_id': id},
      );
      if (response.status < 200 || response.status >= 300) {
        throw StateError('Sync failed');
      }
      final payload = response.data;
      final results = payload is Map ? payload['results'] : null;
      final failed =
          results is List &&
          results.any(
            (r) => r is Map && (r['error'] != null || r['status'] == 'failed'),
          );
      final skipped =
          results is List &&
          results.isNotEmpty &&
          results.every((r) => r is Map && r['skipped'] == true);
      if (mounted) {
        setState(
          () => message = skipped
              ? 'No sync started. The channel may be disabled or a sync is already running.'
              : failed
              ? 'Sync finished with an issue. Review the channel error below.'
              : 'Sync completed. Review imported videos and public totals below.',
        );
      }
      await load();
      await widget.onChanged();
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Sync could not complete. Check server configuration, then refresh channel status before trying again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> configure(
    Map<String, dynamic> channel,
    Map<String, dynamic> current,
  ) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => YoutubeSettingsForm(
        channel: channel,
        current: current,
        sections: widget.sections
            .where(
              (s) => s['channel_id'] == channel['id'] && s['active'] != false,
            )
            .toList(),
      ),
    );
    if (result == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.db.rpc(
        'owner_save_youtube_settings',
        params: {'target': channel['id'], ...result},
      );
      await load();
      if (result['enabled'] == true) await sync('${channel['id']}');
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Could not save sync settings. Check the channel ID, section and owner access.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text(
        'Your channel, connected',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 8),
      const Text(
        'Bring public YouTube videos and playlists into CURLYmax automatically. Review and publish quizzes yourself.',
      ),
      const SizedBox(height: 16),
      if (busy) const LinearProgressIndicator(),
      if (error != null)
        Text(
          error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      if (message != null) Semantics(liveRegion: true, child: Text(message!)),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: busy ? null : load,
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh status'),
        ),
      ),
      if (widget.channels.isEmpty)
        const Text(
          'Create a channel and section first, then connect its YouTube channel.',
        ),
      for (final channel in widget.channels) channelCard(channel),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text(
          'These are public YouTube totals, not private YouTube Analytics. Revenue, watch time and audience demographics are not available here. Metrics update when the server sync runs.',
        ),
      ),
    ],
  );
  Widget channelCard(Map<String, dynamic> channel) {
    final setting =
        settings.where((s) => s['channel_id'] == channel['id']).firstOrNull ??
        <String, dynamic>{};
    final metric =
        analytics.where((s) => s['channel_id'] == channel['id']).firstOrNull ??
        <String, dynamic>{};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${channel['name']}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text('${channel['handle'] ?? ''}'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  avatar: Icon(
                    setting['enabled'] == true
                        ? Icons.sync
                        : Icons.sync_disabled,
                    size: 18,
                  ),
                  label: Text(
                    setting['enabled'] == true
                        ? 'Automatic sync on'
                        : 'Sync off',
                  ),
                ),
                Chip(
                  label: Text(
                    setting['auto_publish'] == true
                        ? 'Videos publish automatically'
                        : 'Import as drafts',
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                for (final entry in {
                  'video_count': 'Videos',
                  'view_count': 'Views',
                  'like_count': 'Likes',
                  'comment_count': 'Comments',
                }.entries)
                  SizedBox(
                    width: 100,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${metric[entry.key] ?? '—'}',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        Text(entry.value),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text('Last synced: ${setting['last_synced_at'] ?? 'Not yet'}'),
            Text('Metrics updated: ${metric['last_metrics_at'] ?? 'Not yet'}'),
            if (setting['running'] == true)
              const Text('Sync is running on the server…'),
            if (setting['last_error'] != null)
              Text(
                '${setting['last_error']}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: busy ? null : () => configure(channel, setting),
                  icon: const Icon(Icons.tune),
                  label: const Text('Configure'),
                ),
                FilledButton.icon(
                  onPressed:
                      busy ||
                          setting['enabled'] != true ||
                          setting['running'] == true
                      ? null
                      : () => sync('${channel['id']}'),
                  icon: const Icon(Icons.sync),
                  label: const Text('Sync now'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class YoutubeSettingsForm extends StatefulWidget {
  final Map<String, dynamic> channel, current;
  final List<Map<String, dynamic>> sections;
  const YoutubeSettingsForm({
    super.key,
    required this.channel,
    required this.current,
    required this.sections,
  });
  @override
  State<YoutubeSettingsForm> createState() => _YoutubeSettingsFormState();
}

class _YoutubeSettingsFormState extends State<YoutubeSettingsForm> {
  final form = GlobalKey<FormState>();
  late final id = TextEditingController(
    text: widget.current['youtube_channel_id'] ?? '',
  );
  late String? section = widget.current['section_id'];
  late bool enabled = widget.current['enabled'] == true;
  late bool autoPublish = widget.current['auto_publish'] != false;
  @override
  void dispose() {
    id.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Connect ${widget.channel['name']}'),
    content: SizedBox(
      width: 500,
      child: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: id,
                decoration: const InputDecoration(
                  labelText: 'YouTube channel ID',
                  helperText:
                      'Optional UC… ID; leave blank to use the channel handle',
                ),
                validator: (v) =>
                    (v?.trim().isEmpty ?? true) ||
                        RegExp(
                          r'^UC[A-Za-z0-9_-]{22}$',
                        ).hasMatch(v?.trim() ?? '')
                    ? null
                    : 'Enter a valid YouTube channel ID',
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: section,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Section for imported videos',
                ),
                items: widget.sections
                    .map(
                      (s) => DropdownMenuItem(
                        value: '${s['id']}',
                        child: Text(
                          '${s['name']}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) => section = v,
                validator: (v) => v == null ? 'Choose a section' : null,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Enable automatic sync'),
                value: enabled,
                onChanged: (v) => setState(() => enabled = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Publish YouTube videos automatically'),
                subtitle: const Text(
                  'Public YouTube videos appear automatically when this is on. Quizzes always stay in draft until you review and publish them.',
                ),
                value: autoPublish,
                onChanged: (v) => setState(() => autoPublish = v),
              ),
              const Text(
                'The server stores the YouTube API key. Never paste credentials here.',
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.pop(context, {
              'youtube_channel_id': id.text.trim().isEmpty
                  ? null
                  : id.text.trim(),
              'section_id': section,
              'enabled': enabled,
              'auto_publish': autoPublish,
            });
          }
        },
        child: const Text('Save settings'),
      ),
    ],
  );
}
