import '../../core/core_storage.dart';

/// Queue the GUI appends to and the engine drains every cycle (2026-10-09,
/// per the user: "if running paused pair un-paused: then a reverse checkup
/// will occur on this pair instantly and then action according to this
/// checkup. if waiting paused pair un-paused: then an instant checkup will
/// be applied to match current filled calculations"). One uppercase base
/// per pending request, appended the instant the Dashboard's Play button
/// un-pauses a pair (see [PausedPairStore]) - the engine runs that one pair
/// through its normal check method with `immediate: true` (the exact same
/// bypass-the-wait machinery the technique-switch reverse-check sweep
/// already uses), which is itself both "a reverse checkup, act accordingly"
/// for a running trade and "an instant checkup against current
/// calculations" for a waiting one - no separate code path needed for the
/// two cases, [EngineService._checkOneSymbol]/[_checkOneSymbolSupertrend]'s
/// own existing running-vs-waiting branches already do the right thing
/// either way. Deliberately not a Set-backed standing flag like
/// [PausedPairStore] - a request is a one-shot command, mirrors
/// [TerminateRequestStore]'s own shape exactly.
class UnpauseCheckRequestStore {
  UnpauseCheckRequestStore(this._storage);

  final CoreStorage _storage;

  Set<String> _readRaw() {
    List<dynamic> arr;
    try {
      arr = _storage.readJsonArrayStrict(_storage.unpauseCheckRequestsFile);
    } catch (_) {
      // A queue file corrupt/missing means no pending requests - a lost
      // instant-checkup request just means this pair waits for its next
      // normal cycle instead, no safety downside to treating it as empty.
      return {};
    }
    return arr.map((e) => e.toString().toUpperCase()).where((e) => e.isNotEmpty).toSet();
  }

  Set<String> loadPending() => _readRaw();

  void request(String base) {
    final set = _readRaw()..add(base.toUpperCase());
    _storage.writeJson(_storage.unpauseCheckRequestsFile, set.toList()..sort());
  }

  /// Removes [base] from the queue - called once the engine has actually
  /// run the immediate checkup for it, so a slow-to-process request doesn't
  /// get re-attempted forever.
  void clear(String base) {
    final set = _readRaw();
    if (set.remove(base.toUpperCase())) {
      _storage.writeJson(_storage.unpauseCheckRequestsFile, set.toList()..sort());
    }
  }
}
