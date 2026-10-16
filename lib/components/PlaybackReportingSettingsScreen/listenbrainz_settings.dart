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
      GlobalSnackbar.message((_) => "ListenBrainz-token borttagen");
      return;
    }
    setState(() => _working = true);
    try {
      final userName = await _service.validateToken(value);
      if (userName == null) {
        GlobalSnackbar.message((_) => "Ogiltig token, inte sparad");
        return;
      }
      await _service.setToken(value);
      GlobalSnackbar.message((_) => "Token sparad för $userName", isConfirmation: true);
    } catch (e) {
      GlobalSnackbar.message((_) => "Kunde inte nå ListenBrainz: $e");
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _submitNow() async {
    setState(() => _working = true);
    try {
      final result = await _service.submitQueue();
      final dropped = result.dropped > 0 ? ", ${result.dropped} för korta borttagna" : "";
      final text = switch (result.status) {
        ListenBrainzSubmitStatus.ok => "Skickade ${result.submitted} lyssningar$dropped",
        ListenBrainzSubmitStatus.nothingToSend => "Inget att skicka$dropped",
        ListenBrainzSubmitStatus.noToken => "Ange en token först",
        ListenBrainzSubmitStatus.invalidToken => "ListenBrainz godkänner inte token",
        ListenBrainzSubmitStatus.rateLimited => "För många anrop, försöker igen senare",
        ListenBrainzSubmitStatus.busy => "Skickar redan",
        ListenBrainzSubmitStatus.failed => "Misslyckades (${result.message}), försöker igen senare",
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
            "Lyssningar som Jellyfin inte fick (offline eller misslyckad rapport) "
            "skickas direkt till ListenBrainz med rätt tid när nätet finns. "
            "Token hittar du på listenbrainz.org/settings.",
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
              title: Text("$countable lyssningar i kö"),
              subtitle: box.length > countable ? Text("${box.length - countable} för korta, skickas inte") : null,
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            children: [
              FilledButton(onPressed: _working ? null : _saveToken, child: const Text("Spara och testa")),
              OutlinedButton(onPressed: _working ? null : _submitNow, child: const Text("Skicka nu")),
            ],
          ),
        ),
      ],
    );
  }
}
