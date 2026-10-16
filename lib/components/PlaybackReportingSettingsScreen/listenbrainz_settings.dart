import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/listenbrainz_service.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

/// Token and queue status for submitting offline listens to ListenBrainz.
class ListenBrainzSettings extends StatefulWidget {
  const ListenBrainzSettings({super.key});

  @override
  State<ListenBrainzSettings> createState() => _ListenBrainzSettingsState();
}

class _ListenBrainzSettingsState extends State<ListenBrainzSettings> {
  final _service = GetIt.instance<ListenBrainzService>();
  late final _controller = TextEditingController(text: _service.token ?? "");
  bool _obscure = true;
  bool _working = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _saveToken() async {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      await _service.setToken(null);
      GlobalSnackbar.message((_) => "ListenBrainz token removed");
      return;
    }
    setState(() => _working = true);
    try {
      final userName = await _service.validateToken(value);
      if (userName == null) {
        GlobalSnackbar.message((_) => "Invalid token, not saved");
        return;
      }
      await _service.setToken(value);
      GlobalSnackbar.message((_) => "Token saved for $userName", isConfirmation: true);
    } catch (e) {
      GlobalSnackbar.message((_) => "Could not reach ListenBrainz: $e");
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _submitNow() async {
    setState(() => _working = true);
    try {
      final result = await _service.submitQueue();
      final dropped = result.dropped > 0 ? ", ${result.dropped} too short, removed" : "";
      final text = switch (result.status) {
        ListenBrainzSubmitStatus.ok => "Submitted ${result.submitted} listens$dropped",
        ListenBrainzSubmitStatus.nothingToSend => "Nothing to submit$dropped",
        ListenBrainzSubmitStatus.noToken => "Enter a token first",
        ListenBrainzSubmitStatus.invalidToken => "ListenBrainz rejected the token",
        ListenBrainzSubmitStatus.rateLimited => "Rate limited, will retry later",
        ListenBrainzSubmitStatus.busy => "Already submitting",
        ListenBrainzSubmitStatus.failed => "Failed (${result.message}), will retry later",
      };
      GlobalSnackbar.message((_) => text);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ListTile(
          title: Text("ListenBrainz"),
          subtitle: Text(
            "Listens Jellyfin never received (offline or failed report) are "
            "submitted directly to ListenBrainz with the correct time once online. "
            "Find your token at listenbrainz.org/settings.",
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _controller,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: "User token",
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onSubmitted: (_) => _saveToken(),
          ),
        ),
        ValueListenableBuilder(
          valueListenable: Hive.box<OfflineListen>("OfflineListens").listenable(),
          builder: (context, box, _) {
            final countable = box.values.where(ListenBrainzService.counts).length;
            return ListTile(
              title: Text("$countable listens queued"),
              subtitle: box.length > countable ? Text("${box.length - countable} too short, won't be submitted") : null,
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            children: [
              FilledButton(onPressed: _working ? null : _saveToken, child: const Text("Save and test")),
              OutlinedButton(onPressed: _working ? null : _submitNow, child: const Text("Submit now")),
            ],
          ),
        ),
      ],
    );
  }
}
