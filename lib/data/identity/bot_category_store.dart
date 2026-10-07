import '../../core/core_storage.dart';
import '../models/auto_category.dart';

/// Which [AutoCategory] a given app-opened position belongs to (position
/// ticket -> category) — MT5 has no such concept natively, this is purely
/// the app's own record, stamped the moment a position is opened under a
/// category. Drives the "(1H)"/"(1m)"/"(1D)" tag shown after a symbol name
/// wherever an auto position appears. Persisted to logs/bot-categories.json,
/// same load/parse-safety pattern as [OpenPositionStore]/[WidenAppliedStore].
class BotCategoryStore {
  BotCategoryStore(this._storage) {
    load();
  }

  final CoreStorage _storage;
  final Map<int, String> _wireByTicket = {};

  Map<int, String> load() {
    final raw = _storage.readJsonObject(_storage.botCategoriesFile) ?? const {};
    _wireByTicket.clear();
    raw.forEach((id, value) {
      final ticket = int.tryParse(id);
      if (ticket != null && value is String) _wireByTicket[ticket] = value;
    });
    return _wireByTicket;
  }

  void _persist() => _storage.writeJson(
    _storage.botCategoriesFile,
    _wireByTicket.map((k, v) => MapEntry(k.toString(), v)),
  );

  /// Reloads from disk on every call — the engine process is this store's
  /// only writer, while the GUI process only ever reads it for display, so
  /// the GUI's in-memory copy must never go stale. Cheap: this file is tiny
  /// and only read at table-render time.
  AutoCategory? categoryOf(int? positionTicket) {
    if (positionTicket == null) return null;
    load();
    return autoCategoryFromWire(_wireByTicket[positionTicket]);
  }

  void setCategory(int positionTicket, AutoCategory category) {
    _wireByTicket[positionTicket] = category.wireValue;
    _persist();
  }

  void forget(int positionTicket) {
    if (_wireByTicket.remove(positionTicket) != null) _persist();
  }
}
