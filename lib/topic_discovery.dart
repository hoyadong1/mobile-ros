import 'ros_connection.dart';

/// Names of topics with message type [type] (ROS 1 or 2 spelling) in a /rosapi/topics answer.
List<String> topicsOfType(Map<String, dynamic>? topics, String type) {
  final names = (topics?['topics'] as List?)?.map((v) => '$v').toList() ?? const <String>[];
  final types = (topics?['types'] as List?)?.map((v) => '$v'.replaceFirst('/msg/', '/')).toList() ?? const <String>[];
  final want = type.replaceFirst('/msg/', '/');
  return [for (var i = 0; i < names.length && i < types.length; i++) if (types[i] == want) names[i]];
}

/// [candidates] ordered by how well their name matches [conventional]: exact `/name` first, then any
/// namespace ending in `/name`, then the rest in their original order.
List<String> rankByName(List<String> candidates, String conventional) {
  int score(String t) => t == '/$conventional' ? 0 : t.endsWith('/$conventional') ? 1 : 2;
  final indexed = [for (var i = 0; i < candidates.length; i++) (i, candidates[i])];
  indexed.sort((a, b) => score(a.$2) != score(b.$2) ? score(a.$2).compareTo(score(b.$2)) : a.$1.compareTo(b.$1));
  return [for (final e in indexed) e.$2];
}

enum TopicRole { read, write }

/// Picks the topic of [type] to use, preferring the conventional name but skipping topics that are
/// listed without anyone on the other end. rosapi lists a topic as long as anything references it, so
/// a stale `/odom` with only subscribers (left over from another tool) must not win over the namespaced
/// `/robot1/odom` that is actually published. For [TopicRole.read] a publisher is required; for
/// [TopicRole.write] a subscriber. If rosapi cannot answer, the name ranking alone decides.
Future<String?> pickTopic(RosConnection client, Map<String, dynamic>? topics, String type, String conventional,
    {TopicRole role = TopicRole.read}) async {
  final ranked = rankByName(topicsOfType(topics, type), conventional);
  if (ranked.length <= 1) return ranked.firstOrNull;
  final service = role == TopicRole.read ? '/rosapi/publishers' : '/rosapi/subscribers';
  final key = role == TopicRole.read ? 'publishers' : 'subscribers';
  for (final topic in ranked) {
    try {
      final answer = await client.call(service, {'topic': topic});
      final nodes = answer[key];
      if (nodes is List && nodes.isNotEmpty) return topic;
    } catch (_) {
      return ranked.first; // no rosapi introspection: trust the names
    }
  }
  return ranked.first;
}
