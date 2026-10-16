import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// Result of a submission attempt, shown in the settings screen.
enum ListenBrainzSubmitStatus { ok, noToken, nothingToSend, invalidToken, rateLimited, failed, busy }

class ListenBrainzSubmitResult {
  const ListenBrainzSubmitResult(this.status, {this.submitted = 0, this.dropped = 0, this.message});

  final ListenBrainzSubmitStatus status;
  final int submitted;

  /// Listens removed from the queue without being sent (too short, or rejected by ListenBrainz).
  final int dropped;
  final String? message;
}

/// Submits listens from the offline listen queue directly to ListenBrainz.
///
/// Online listens are scrobbled by the Jellyfin ListenBrainz plugin from the
/// playback reports. Listens end up in the offline queue only when Jellyfin
/// never received them (offline mode or a failed report), so sending the queue
/// here does not create duplicates.
class ListenBrainzService {
  static const boxName = "ListenBrainz";
  static const _tokenKey = "token";
  static const _apiBase = "https://api.listenbrainz.org/1";
  static const _batchSize = 100;
  static const _clientName = "finampBrainz";

  final _logger = Logger("ListenBrainzService");
  bool _submitting = false;
  bool _wasOffline = FinampSettingsHelper.finampSettings.isOffline;
  Timer? _debounce;

  Box<String> get _box => Hive.box<String>(boxName);
  Box<OfflineListen> get _queue => Hive.box<OfflineListen>("OfflineListens");

  ListenBrainzService() {
    // Jellyfin may be unreachable (offline mode) while the internet works, so
    // try whenever there is any network instead of waiting for offline mode to end.
    Connectivity().onConnectivityChanged.listen((connections) {
      if (connections.any((c) => c != ConnectivityResult.none)) _scheduleSubmit();
    });
    FinampSettingsHelper.finampSettingsListener.addListener(() {
      final isOffline = FinampSettingsHelper.finampSettings.isOffline;
      if (_wasOffline && !isOffline) _scheduleSubmit();
      _wasOffline = isOffline;
    });
    // Catches listens logged after failed reports while the network state never changed.
    Timer.periodic(const Duration(minutes: 15), (_) {
      if (_queue.isNotEmpty) _scheduleSubmit();
    });
    _scheduleSubmit(delay: const Duration(seconds: 20));
  }

  String? get token {
    final value = _box.get(_tokenKey);
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> setToken(String? value) async {
    final trimmed = value?.trim() ?? "";
    if (trimmed.isEmpty) {
      await _box.delete(_tokenKey);
    } else {
      await _box.put(_tokenKey, trimmed);
      _scheduleSubmit();
    }
  }

  /// Returns the ListenBrainz user name for [value], or null if the token is invalid.
  Future<String?> validateToken(String value) async {
    final response = await http
        .get(Uri.parse("$_apiBase/validate-token"), headers: {"Authorization": "Token ${value.trim()}"})
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) return null;
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body["valid"] == true ? body["user_name"] as String? : null;
  }

  void _scheduleSubmit({Duration delay = const Duration(seconds: 10)}) {
    _debounce?.cancel();
    _debounce = Timer(delay, () => submitQueue());
  }

  /// Uses the same rule as ListenBrainz and the Jellyfin plugin: a listen counts
  /// after half the track or four minutes, whichever comes first.
  static bool counts(OfflineListen listen) {
    final played = listen.playedSeconds;
    if (played == null) return true;
    if (played >= 240) return true;
    final duration = listen.durationSeconds;
    return duration != null && duration > 0 && played * 2 >= duration;
  }

  /// The queue stores the stop time; ListenBrainz expects the start time.
  static int listenedAt(OfflineListen listen) => listen.timestamp - (listen.playedSeconds ?? 0);

  static String? _artistName(OfflineListen listen) {
    final artists = listen.artists;
    if (artists != null && artists.isNotEmpty) return artists.join(", ");
    return listen.artist;
  }

  static Map<String, dynamic> toPayload(OfflineListen listen) {
    final additionalInfo = <String, dynamic>{
      "media_player": _clientName,
      "submission_client": _clientName,
      if (listen.durationSeconds != null) "duration_ms": listen.durationSeconds! * 1000,
      if (listen.recordingMbid != null) "recording_mbid": listen.recordingMbid,
      if (listen.releaseMbid != null) "release_mbid": listen.releaseMbid,
      if (listen.releaseGroupMbid != null) "release_group_mbid": listen.releaseGroupMbid,
      if (listen.trackMbid != null) "track_mbid": listen.trackMbid,
      if (listen.artistMbids != null && listen.artistMbids!.isNotEmpty) "artist_mbids": listen.artistMbids,
    };
    return {
      "listened_at": listenedAt(listen),
      "track_metadata": {
        "artist_name": _artistName(listen),
        "track_name": listen.name,
        if (listen.album != null) "release_name": listen.album,
        "additional_info": additionalInfo,
      },
    };
  }

  /// Sends every countable listen in the queue and removes it once ListenBrainz accepts it.
  Future<ListenBrainzSubmitResult> submitQueue() async {
    final currentToken = token;
    if (currentToken == null) return const ListenBrainzSubmitResult(ListenBrainzSubmitStatus.noToken);
    if (_submitting) return const ListenBrainzSubmitResult(ListenBrainzSubmitStatus.busy);
    _submitting = true;
    try {
      // Too short or without an artist: ListenBrainz would ignore or reject them.
      // They stay in listens.json, so nothing is lost.
      final droppedKeys = _queue.keys
          .where((key) {
            final listen = _queue.get(key)!;
            return !counts(listen) || (_artistName(listen)?.isEmpty ?? true);
          })
          .toList();
      for (final key in droppedKeys) {
        final listen = _queue.get(key)!;
        _logger.info(
          "Not sending ${listen.name}: played ${listen.playedSeconds}s of ${listen.durationSeconds}s, "
          "artist '${_artistName(listen)}'",
        );
      }
      await _queue.deleteAll(droppedKeys);
      var dropped = droppedKeys.length;

      final keys = _queue.keys.toList();
      _logger.info("Submitting ${keys.length} listens to ListenBrainz, dropped ${droppedKeys.length}");
      if (keys.isEmpty) {
        return ListenBrainzSubmitResult(ListenBrainzSubmitStatus.nothingToSend, dropped: dropped);
      }

      var submitted = 0;
      for (var start = 0; start < keys.length; start += _batchSize) {
        final batch = keys.sublist(start, (start + _batchSize).clamp(0, keys.length));
        final response = await _post(currentToken, batch);
        if (response.statusCode == 200) {
          await _queue.deleteAll(batch);
          submitted += batch.length;
          continue;
        }
        if (response.statusCode == 400) {
          // One bad listen rejects the whole batch, so retry them one by one.
          for (final key in batch) {
            final single = await _post(currentToken, [key]);
            if (single.statusCode == 200) {
              submitted++;
            } else if (single.statusCode == 400) {
              _logger.warning("ListenBrainz rejected ${_queue.get(key)?.name}: ${single.body}");
              dropped++;
            } else {
              return _failure(single, submitted, dropped);
            }
            await _queue.delete(key);
          }
          continue;
        }
        return _failure(response, submitted, dropped);
      }
      _logger.info("Submitted $submitted listens to ListenBrainz, dropped $dropped");
      return ListenBrainzSubmitResult(ListenBrainzSubmitStatus.ok, submitted: submitted, dropped: dropped);
    } catch (e) {
      _logger.info("ListenBrainz submission failed, will retry later: $e");
      return ListenBrainzSubmitResult(ListenBrainzSubmitStatus.failed, message: e.toString());
    } finally {
      _submitting = false;
    }
  }

  Future<http.Response> _post(String currentToken, List<dynamic> keys) {
    final body = jsonEncode({
      "listen_type": "import",
      "payload": keys.map((key) => toPayload(_queue.get(key)!)).toList(),
    });
    return http
        .post(
          Uri.parse("$_apiBase/submit-listens"),
          headers: {"Authorization": "Token $currentToken", "Content-Type": "application/json"},
          body: body,
        )
        .timeout(const Duration(seconds: 30));
  }

  ListenBrainzSubmitResult _failure(http.Response response, int submitted, int dropped) {
    _logger.warning("ListenBrainz submission failed (${response.statusCode}): ${response.body}");
    final status = switch (response.statusCode) {
      401 => ListenBrainzSubmitStatus.invalidToken,
      429 => ListenBrainzSubmitStatus.rateLimited,
      _ => ListenBrainzSubmitStatus.failed,
    };
    return ListenBrainzSubmitResult(
      status,
      submitted: submitted,
      dropped: dropped,
      message: "HTTP ${response.statusCode}",
    );
  }
}
