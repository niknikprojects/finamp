import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/listenbrainz_service.dart';
import 'package:flutter_test/flutter_test.dart';

OfflineListen _listen({int? played, int? duration, List<String>? artists, String? artist = "Album Artist"}) =>
    OfflineListen(
      timestamp: 1700000300,
      userId: "user",
      itemId: "item",
      name: "Track",
      artist: artist,
      album: "Album",
      playedSeconds: played,
      durationSeconds: duration,
      artists: artists,
      recordingMbid: "rec-mbid",
      artistMbids: ["a1", "a2"],
    );

void main() {
  group('ListenBrainz listen rule', () {
    test('counts after half the track', () {
      expect(ListenBrainzService.counts(_listen(played: 100, duration: 200)), isTrue);
      expect(ListenBrainzService.counts(_listen(played: 99, duration: 200)), isFalse);
    });

    test('counts after four minutes of a long track', () {
      expect(ListenBrainzService.counts(_listen(played: 240, duration: 1200)), isTrue);
      expect(ListenBrainzService.counts(_listen(played: 239, duration: 1200)), isFalse);
    });

    test('skips without a known duration unless four minutes played', () {
      expect(ListenBrainzService.counts(_listen(played: 30)), isFalse);
    });

    test('keeps listens logged before played time was tracked', () {
      expect(ListenBrainzService.counts(_listen()), isTrue);
    });
  });

  group('ListenBrainz payload', () {
    test('uses start time, track artists and MBIDs', () {
      final payload = ListenBrainzService.toPayload(_listen(played: 200, duration: 200, artists: ["A", "B"]));
      expect(payload["listened_at"], 1700000100);
      final metadata = payload["track_metadata"] as Map<String, dynamic>;
      expect(metadata["artist_name"], "A, B");
      expect(metadata["track_name"], "Track");
      expect(metadata["release_name"], "Album");
      final info = metadata["additional_info"] as Map<String, dynamic>;
      expect(info["duration_ms"], 200000);
      expect(info["recording_mbid"], "rec-mbid");
      expect(info["artist_mbids"], ["a1", "a2"]);
      expect(info.containsKey("release_mbid"), isFalse);
    });

    test('falls back to album artist', () {
      final metadata = ListenBrainzService.toPayload(_listen(played: 200, duration: 200))["track_metadata"] as Map;
      expect(metadata["artist_name"], "Album Artist");
    });
  });
}
