/// The multi-device sequencer's coordinator, on loopback beside the relay.
///
/// `--dart-define` is compile-time, so a lane that gives each device its own
/// phase needs its own binary per device — and two builds at once in this
/// project's single `build/` directory leave every device running whichever
/// finished last. Claiming the role at runtime means every device is launched
/// with the same defines, built once, and started together.
///
/// The compile-time defines still work, for running one device by hand: each
/// call takes the fallback its lane would otherwise have been given.
library;

import 'dart:convert';
import 'dart:io';

/// Where this device asks which device it is, or empty when the lane is being
/// driven by hand.
const splitsCoordinator = String.fromEnvironment('SPLITS_COORDINATOR');

/// Takes the next unclaimed role, in arrival order.
Future<String> claimRole({required String fallback}) async {
  if (splitsCoordinator.isEmpty) return fallback;
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse('$splitsCoordinator/claim'));
    final response = await request.close();
    final body = await response.transform(const Utf8Decoder()).join();
    if (response.statusCode != 200) {
      throw StateError('the coordinator gave out no role: $body');
    }
    return (jsonDecode(body) as Map<String, dynamic>)['role'] as String;
  } finally {
    client.close();
  }
}

/// Publishes [value] under [key] for the other devices to read.
Future<void> publish(String key, String value) async {
  if (splitsCoordinator.isEmpty) return;
  final client = HttpClient();
  try {
    final request = await client.putUrl(
      Uri.parse('$splitsCoordinator/kv/$key'),
    );
    final body = utf8.encode(value);
    // Without a declared length the body goes out chunked, and the coordinator
    // reads exactly the number of bytes `content-length` names. A value that
    // arrives empty is indistinguishable from one deliberately left empty, and
    // every device awaiting the key reads it as real.
    request.headers.contentLength = body.length;
    request.add(body);
    final response = await request.close();
    await response.drain<void>();
    if (response.statusCode != 204) {
      throw StateError('the coordinator refused $key: ${response.statusCode}');
    }
  } finally {
    client.close();
  }
}

/// Reads [key] once, or null while nobody has published it.
///
/// For a device that has to keep pumping its own app while it waits: a lane
/// that blocks on [awaitValue] stops driving the widget tree, and an app that
/// is not pumped does no work.
Future<String?> peek(String key) async {
  if (splitsCoordinator.isEmpty) return null;
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('$splitsCoordinator/kv/$key'),
    );
    final response = await request.close();
    final body = await response.transform(const Utf8Decoder()).join();
    if (response.statusCode == 200) return body;
    if (response.statusCode != 404) {
      throw StateError(
        'the coordinator answered $key with '
        '${response.statusCode}: $body',
      );
    }
    return null;
  } finally {
    client.close();
  }
}

/// Waits for another device to publish [key].
///
/// 404 is "not yet" and is polled; anything else is a fault worth stopping
/// for. A lane that treated every failure as "not yet" would wait out its
/// whole timeout against a coordinator that was never running.
Future<String> awaitValue(
  String key, {
  required Duration timeout,
  required String fallback,
}) async {
  if (splitsCoordinator.isEmpty) return fallback;
  final end = DateTime.now().add(timeout);
  final client = HttpClient();
  try {
    while (DateTime.now().isBefore(end)) {
      final request = await client.getUrl(
        Uri.parse('$splitsCoordinator/kv/$key'),
      );
      final response = await request.close();
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode == 200) return body;
      if (response.statusCode != 404) {
        throw StateError(
          'the coordinator answered $key with '
          '${response.statusCode}: $body',
        );
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  } finally {
    client.close();
  }
  throw StateError('nobody published $key within $timeout');
}
