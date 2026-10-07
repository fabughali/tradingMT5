/// Live health state behind the Power toggle (2026-09-20, per the user).
/// Power always starts [off] on every fresh engine start (see
/// `EngineService.run()`) — switching it on kicks off a layered check run
/// in this dependency order: internet, then MT5, then TradingView/its two
/// required indicators (worm_9_26 + spy_9_26) — and that check keeps
/// re-running every cycle for as long as Power stays on, not just once at
/// switch-on.
enum PowerHealthState {
  /// Power switch is off (or the engine isn't running at all).
  off,

  /// Power just switched on; the very first check run hasn't produced a
  /// result yet. Shown as a blinking green dot, never reappears on later
  /// cycles while Power stays on — see [EngineService._runHealthCheck].
  checking,

  /// All three checks passed on the most recent cycle.
  ready,

  /// No internet reachability — checked first, since nothing else can work
  /// without it.
  internetProblem,

  /// MT5's MCP server isn't reachable (and didn't come up after an
  /// auto-launch attempt, despite genuinely being installed).
  mt5Problem,

  /// TradingView's CDP port isn't reachable, or the chart is up but
  /// worm_9_26/spy_9_26 aren't both attached and re-enforcing failed.
  tradingViewProblem,

  /// MT5 genuinely isn't installed at the expected path (2026-10-07, per
  /// the user: "app need to be smart... if mt5 is not setup... app need to
  /// show a dialog that user need to install") - distinct from
  /// [mt5Problem] (installed but not cooperating) because the fix is
  /// completely different: install the app, not troubleshoot a stuck
  /// process. Checked BEFORE ever attempting to launch, so a missing
  /// install fails fast with a clear message instead of a confusing
  /// process-spawn error.
  mt5NotInstalled,

  /// Same distinction as [mt5NotInstalled], for TradingView Desktop.
  tradingViewNotInstalled;

  static PowerHealthState fromWire(String? value) => switch (value) {
    'checking' => PowerHealthState.checking,
    'ready' => PowerHealthState.ready,
    'internet_problem' => PowerHealthState.internetProblem,
    'mt5_problem' => PowerHealthState.mt5Problem,
    'tradingview_problem' => PowerHealthState.tradingViewProblem,
    'mt5_not_installed' => PowerHealthState.mt5NotInstalled,
    'tradingview_not_installed' => PowerHealthState.tradingViewNotInstalled,
    _ => PowerHealthState.off,
  };

  String get wireValue => switch (this) {
    PowerHealthState.off => 'off',
    PowerHealthState.checking => 'checking',
    PowerHealthState.ready => 'ready',
    PowerHealthState.internetProblem => 'internet_problem',
    PowerHealthState.mt5Problem => 'mt5_problem',
    PowerHealthState.tradingViewProblem => 'tradingview_problem',
    PowerHealthState.mt5NotInstalled => 'mt5_not_installed',
    PowerHealthState.tradingViewNotInstalled => 'tradingview_not_installed',
  };
}
