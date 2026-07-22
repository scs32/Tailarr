import 'package:flutter_test/flutter_test.dart';
import 'package:lunasea/api/ntfy/models.dart';

void main() {
  group('NtfySubscription.parse', () {
    test('parses the server handout JSON', () {
      final sub = NtfySubscription.parse(
        '{"url": "https://ntfy.taila06ea9.ts.net/", "token": "tk_abc123", '
        '"topics": ["tlr-ops", "tlr-media-sonarr"]}',
      );
      expect(sub, isNotNull);
      expect(sub!.url, 'https://ntfy.taila06ea9.ts.net');
      expect(sub.token, 'tk_abc123');
      expect(sub.topics, ['tlr-ops', 'tlr-media-sonarr']);
    });

    test('parses a tailarr://ntfy deep link', () {
      final sub = NtfySubscription.parse(
        'tailarr://ntfy?url=https%3A%2F%2Fntfy.example.ts.net'
        '&token=tk_abc&topics=tlr-ops,tlr-media-radarr',
      );
      expect(sub, isNotNull);
      expect(sub!.url, 'https://ntfy.example.ts.net');
      expect(sub.token, 'tk_abc');
      expect(sub.topics, ['tlr-ops', 'tlr-media-radarr']);
    });

    test('rejects garbage and incomplete payloads', () {
      expect(NtfySubscription.parse('not json {'), isNull);
      expect(NtfySubscription.parse('{"token": "tk_x"}'), isNull);
      expect(NtfySubscription.parse('{"url": "https://x", "topics": []}'),
          isNull);
    });
  });

  group('NtfyMessage.fromLine', () {
    test('parses a message event', () {
      final message = NtfyMessage.fromLine(
        '{"id":"a1b2c3","time":1753200000,"event":"message",'
        '"topic":"tlr-ops","title":"Update Available","message":"sonarr",'
        '"priority":4,"tags":["warning"]}',
      );
      expect(message, isNotNull);
      expect(message!.isMessage, isTrue);
      expect(message.id, 'a1b2c3');
      expect(message.time, 1753200000);
      expect(message.title, 'Update Available');
      expect(message.priority, 4);
      expect(message.tags, ['warning']);
    });

    test('keepalive and open events are not messages', () {
      final keepalive = NtfyMessage.fromLine(
          '{"id":"x","time":1,"event":"keepalive","topic":"tlr-ops"}');
      expect(keepalive!.isMessage, isFalse);
      final open = NtfyMessage.fromLine(
          '{"id":"y","time":1,"event":"open","topic":"tlr-ops"}');
      expect(open!.isMessage, isFalse);
    });

    test('blank and broken lines return null', () {
      expect(NtfyMessage.fromLine(''), isNull);
      expect(NtfyMessage.fromLine('   '), isNull);
      expect(NtfyMessage.fromLine('{broken'), isNull);
      expect(NtfyMessage.fromLine('[1,2,3]'), isNull);
    });

    test('defaults are applied for missing fields', () {
      final message = NtfyMessage.fromLine(
          '{"id":"z","time":2,"event":"message","topic":"tlr-ops"}');
      expect(message!.priority, 3);
      expect(message.tags, isEmpty);
      expect(message.title, isNull);
    });
  });

  group('ntfyTopicLabel', () {
    test('maps known topics', () {
      expect(ntfyTopicLabel('tlr-ops'), 'Server');
      expect(ntfyTopicLabel('tlr-media-sonarr'), 'Sonarr');
      expect(ntfyTopicLabel('tlr-media-radarr'), 'Radarr');
    });

    test('passes through unknown topics', () {
      expect(ntfyTopicLabel('random-topic'), 'random-topic');
      expect(ntfyTopicLabel('tlr-media-'), 'tlr-media-');
    });
  });
}
