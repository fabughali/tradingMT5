import '../../core/core_storage.dart';

/// Queue the GUI appends to and the engine drains every cycle (2026-09-29,
/// per the user's Dashboard-table spec: "a power switch icon per each
/// pair, once it is pressed, trade will be terminated"). One uppercase
/// base per pending request; the engine removes an entry once it has
/// actually closed that base's position. Deliberately not a Set-backed
/// store like [LastTagStore]/[RetiredStore] - a request is a one-shot
/// command, not a standing flag, so `take()` both reads and clears it.
class TerminateRequestStore {
  TerminateRequestStore(this._storage);

  final CoreStorage _storage;

  Set<String> _readRaw() {
    List<dynamic> arr;
    try {
      arr = _storage.readJsonArrayStrict(_storage.terminateRequestsFile);
    } catch (_) {
      // A queue file corrupt/missing means no pending requests - unlike
      // RetiredStore/LastTagStore this has no safety downside to treating
      // corruption as empty (a lost terminate request just means the user
      // presses the power icon again).
      return {};
    }
    return arr.map((e) => e.toString().toUpperCase()).where((e) => e.isNotEmpty).toSet();
  }

  Set<String> loadPending() => _readRaw();

  void request(String base) {
    final set = _readRaw()..add(base.toUpperCase());
    _storage.writeJson(_storage.terminateRequestsFile, set.toList()..sort());
  }

  /// Removes [base] from the queue - called once the engine has actually
  /// closed its position, so a slow-to-process request doesn't get
  /// re-attempted forever if closing genuinely fails.
  void clear(String base) {
    final set = _readRaw();
    if (set.remove(base.toUpperCase())) {
      _storage.writeJson(_storage.terminateRequestsFile, set.toList()..sort());
    }
  }
}
