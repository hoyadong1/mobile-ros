import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the assistant knows about its person and each robot, kept on the phone.
///
/// Everything is one kind of record, [MemoryItem], in a scope: `user` (the person, shared by every
/// robot) or `robot:<address>` (one robot). A record has a [MemoryItem.kind] — `profile` for keyed
/// facts (the robot's name, what to call the person), `note` for things to keep in mind, and later
/// `alias`, `episode`, `habit` — so new kinds of knowledge need no new storage. Where records live is
/// behind [MemoryStore]: one JSON document per scope now; a database later without touching callers.
class MemoryItem {
  const MemoryItem({required this.id, required this.kind, this.key, required this.text, this.source = 'person',
      required this.created, required this.updated, this.lastUsed, this.uses = 0, this.pinned = false, this.data});

  final String id;
  /// `profile`, `note`, `alias`, `episode`, `habit`, ...
  final String kind;
  /// For keyed facts: at most one item per (kind, key), e.g. (`profile`, `name`).
  final String? key;
  final String text;
  /// Who said it: `person` (typed or answered), `assistant` (learned in a conversation), `app` (found).
  final String source;
  final DateTime created, updated;
  /// When it last went into the assistant's context, and how often: what is used stays.
  final DateTime? lastUsed;
  final int uses;
  /// Never dropped to make room (the person's own profile answers are pinned).
  final bool pinned;
  /// Structured content beside the searchable [text] (a learned tool's definition, the calls of an episode).
  final Map<String, Object?>? data;

  MemoryItem copyWith({String? text, String? source, DateTime? updated, DateTime? lastUsed, int? uses, bool? pinned,
      Map<String, Object?>? data}) =>
      MemoryItem(id: id, kind: kind, key: key, text: text ?? this.text, source: source ?? this.source,
          created: created, updated: updated ?? this.updated, lastUsed: lastUsed ?? this.lastUsed,
          uses: uses ?? this.uses, pinned: pinned ?? this.pinned, data: data ?? this.data);

  Map<String, Object?> toJson() => {
    'id': id, 'kind': kind, 'key': ?key, 'text': text,
    if (source != 'person') 'src': source,
    'c': created.millisecondsSinceEpoch, 'u': updated.millisecondsSinceEpoch,
    if (lastUsed != null) 'l': lastUsed!.millisecondsSinceEpoch,
    if (uses != 0) 'n': uses,
    if (pinned) 'p': true,
    'd': ?data,
  };

  static MemoryItem? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], kind = j['kind'], text = j['text'], c = j['c'], u = j['u'];
    if (id is! String || kind is! String || text is! String || text.isEmpty || c is! int || u is! int) return null;
    final key = j['key'], l = j['l'], n = j['n'], src = j['src'];
    return MemoryItem(id: id, kind: kind, key: key is String ? key : null, text: text,
        source: src is String ? src : 'person',
        created: DateTime.fromMillisecondsSinceEpoch(c), updated: DateTime.fromMillisecondsSinceEpoch(u),
        lastUsed: l is int ? DateTime.fromMillisecondsSinceEpoch(l) : null, uses: n is int ? n : 0, pinned: j['p'] == true,
        data: j['d'] is Map ? Map<String, Object?>.from(j['d'] as Map) : null);
  }
}

/// Where a scope's records are kept.
abstract class MemoryStore {
  Future<List<MemoryItem>> read(String scope);
  Future<void> write(String scope, List<MemoryItem> items);
  Future<void> delete(String scope);
}

/// One JSON document per scope in the app's preferences (works on phones, desktop and the web).
class PrefsMemoryStore implements MemoryStore {
  const PrefsMemoryStore();
  static String keyOf(String scope) => 'memory:$scope';

  @override
  Future<List<MemoryItem>> read(String scope) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(keyOf(scope));
      final list = raw == null ? const [] : jsonDecode(raw);
      return [if (list is List) for (final j in list) ?MemoryItem.fromJson(j)];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> write(String scope, List<MemoryItem> items) async =>
      (await SharedPreferences.getInstance()).setString(keyOf(scope), jsonEncode([for (final i in items) i.toJson()]));

  @override
  Future<void> delete(String scope) async => (await SharedPreferences.getInstance()).remove(keyOf(scope));
}

/// One scope's records: read once, changed in memory, written back after each change.
class Memory extends ChangeNotifier {
  Memory(this.scope, {MemoryStore? store, this.maxItems = 300, DateTime Function()? clock})
      : store = store ?? const PrefsMemoryStore(), _now = clock ?? DateTime.now;

  /// The person: shared by every robot and screen.
  static final Memory user = Memory('user');
  /// One robot, by its address (and namespace).
  static String robotScope(String address) => 'robot:$address';

  final String scope;
  final MemoryStore store;
  /// Beyond this, unpinned items that were used least and longest ago go first.
  final int maxItems;
  final DateTime Function() _now;
  List<MemoryItem> _items = const [];
  bool _loaded = false;
  int _next = 0;

  List<MemoryItem> get items => _items;
  /// The time as this memory keeps it (its clock).
  DateTime get now => _now();
  bool get loaded => _loaded;

  /// Reads the scope once. No pending read is shared between callers: a read started in a zone that is
  /// gone (a closed screen, a finished test) must not leave later callers waiting forever.
  Future<void> load() async {
    if (_loaded) return;
    final items = await store.read(scope);
    if (_loaded) return; // another read finished first, and may have been changed since
    _items = items;
    _loaded = true;
    notifyListeners();
  }

  /// Reads it again (another screen may have changed it).
  Future<void> reload() {
    _loaded = false;
    return load();
  }

  /// Drops what was read, so the next [load] reads the store again (tests reset the stored values).
  @visibleForTesting
  void unload() {
    _items = const [];
    _loaded = false;
  }

  Iterable<MemoryItem> ofKind(String kind) => _items.where((i) => i.kind == kind);
  MemoryItem? item(String kind, String key) => _items.where((i) => i.kind == kind && i.key == key).firstOrNull;
  /// A keyed profile fact (`name`, `call_me`, ...), or null.
  String? profile(String key) => item('profile', key)?.text;

  /// Sets, replaces or (with an empty [text]) removes the keyed fact.
  Future<void> setProfile(String key, String? text, {String source = 'person'}) =>
      put('profile', key, text, source: source, pinned: true);

  /// Adds a record of [kind] (a note, an episode...); an identical one is refreshed instead.
  /// [at]: when it happened, if not now (a summary of older records keeps their date).
  Future<MemoryItem?> add(String kind, String text, {String source = 'person', bool pinned = false,
      Map<String, Object?>? data, DateTime? at}) async {
    await load();
    final t = _clean(text);
    if (t == null) return null;
    final now = at ?? _now();
    final same = _items.where((i) => i.kind == kind && i.key == null && i.text == t).firstOrNull;
    final item = same?.copyWith(updated: now, source: source, pinned: pinned || same.pinned, data: data) ??
        MemoryItem(id: '${now.microsecondsSinceEpoch.toRadixString(36)}${(_next++).toRadixString(36)}', kind: kind,
            text: t, source: source, created: now, updated: now, pinned: pinned, data: data);
    _items = [for (final i in _items) if (i.id != item.id) i, item];
    await _save();
    return item;
  }

  /// Removes several records with one write.
  Future<void> removeAll(Iterable<String> ids) async {
    await load();
    final gone = ids.toSet();
    _items = [for (final i in _items) if (!gone.contains(i.id)) i];
    await _save();
  }

  Future<void> remove(String id) async {
    await load();
    _items = [for (final i in _items) if (i.id != id) i];
    await _save();
  }

  /// Forgets everything in this scope.
  Future<void> clear() async {
    _items = const [];
    _loaded = true;
    notifyListeners();
    await store.delete(scope);
  }

  /// Marks [used] as having gone into the assistant's context (so they are kept and ranked up).
  Future<void> touch(Iterable<MemoryItem> used) async {
    final ids = {for (final i in used) i.id};
    if (ids.isEmpty) return;
    final now = _now();
    _items = [for (final i in _items) ids.contains(i.id) ? i.copyWith(lastUsed: now, uses: i.uses + 1) : i];
    await _save(notify: false);
  }

  /// The unkeyed records most worth giving the assistant for [query], within [budget] characters:
  /// pinned ones first, then by shared words with the query, then by use and recency.
  List<MemoryItem> relevant(String query, {Set<String> kinds = const {'note'}, int budget = 600}) {
    final words = _words(query);
    final now = _now();
    double score(MemoryItem i) {
      final overlap = words.isEmpty ? 0 : _words(i.text).intersection(words).length;
      final age = now.difference(i.lastUsed ?? i.updated).inHours / 24;
      return (i.pinned ? 100 : 0) + overlap * 10 + math.log(1 + i.uses) * 2 - math.min(age, 365) / 30;
    }
    final ranked = _items.where((i) => kinds.contains(i.kind)).toList()..sort((a, b) => score(b).compareTo(score(a)));
    final out = <MemoryItem>[];
    var used = 0;
    for (final i in ranked) {
      if (used + i.text.length > budget) continue;
      out.add(i);
      used += i.text.length;
    }
    return out;
  }

  /// Sets, replaces or (with an empty [text]) removes the record of [kind] keyed [key].
  Future<void> put(String kind, String key, String? text, {String source = 'person', bool pinned = false,
      Map<String, Object?>? data}) async {
    await load();
    final t = _clean(text);
    final old = item(kind, key);
    if (t == null) {
      if (old == null) return;
      _items = [for (final i in _items) if (i.id != old.id) i];
    } else {
      final now = _now();
      final next = old?.copyWith(text: t, source: source, updated: now, pinned: pinned, data: data) ??
          MemoryItem(id: '$kind:$key', kind: kind, key: key, text: t, source: source, created: now, updated: now,
              pinned: pinned, data: data);
      _items = [for (final i in _items) if (i.id != next.id) i, next];
    }
    await _save();
  }

  Future<void> _save({bool notify = true}) async {
    if (_items.length > maxItems) {
      final drop = _items.where((i) => !i.pinned).toList()
        ..sort((a, b) {
          final byUse = a.uses.compareTo(b.uses);
          return byUse != 0 ? byUse : (a.lastUsed ?? a.updated).compareTo(b.lastUsed ?? b.updated);
        });
      final gone = {for (final i in drop.take(_items.length - maxItems)) i.id};
      _items = [for (final i in _items) if (!gone.contains(i.id)) i];
    }
    if (notify) notifyListeners();
    try {
      await store.write(scope, _items);
      lastError = null;
    } catch (e) {
      // Kept in memory for this run; a screen may show [lastError]. Never thrown at the person's command.
      lastError = '$e';
    }
  }

  /// Why the last write to the store failed, or null.
  String? lastError;

  static String? _clean(String? s) {
    final t = s?.trim();
    if (t == null || t.isEmpty) return null;
    return t.length > 300 ? t.substring(0, 300) : t;
  }

  static Set<String> _words(String s) => {
    for (final w in s.toLowerCase().split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)))
      if (w.length >= 2) w,
  };
}
