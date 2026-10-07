import 'auto_category.dart';

/// Live state of the Power/Auto/per-category control-file toggles — pure
/// local file-existence checks (see EngineControlRepository), cheap enough
/// to poll fast so the Dashboard's switches feel responsive.
class ControlToggleState {
  const ControlToggleState({
    required this.powerOn,
    required this.autoOn,
    required this.categoryOn,
  });

  final bool powerOn;
  final bool autoOn;
  final Map<AutoCategory, bool> categoryOn;
}
