/// Broker connection settings for MT5's native MCP server (build 6140+) —
/// see ARCHITECTURE.md for why this was chosen over an MQL5-EA/file bridge
/// or WebTerminal automation. Auth key lives in `.env` (MT5_MCP_API_KEY),
/// never here.
class Mt5Config {
  const Mt5Config({this.mcpHost = '127.0.0.1', this.mcpPort = 22346});

  final String mcpHost;
  final int mcpPort;

  factory Mt5Config.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const Mt5Config();
    return Mt5Config(
      mcpHost: json['mcp_host'] as String? ?? '127.0.0.1',
      mcpPort: (json['mcp_port'] as num?)?.toInt() ?? 22346,
    );
  }

  Map<String, dynamic> toJson() => {'mcp_host': mcpHost, 'mcp_port': mcpPort};
}

/// TradingView Desktop's Chrome DevTools Protocol debug port — the same
/// signal-reading connection tradingPionex uses, ported unchanged since
/// signal reading is entirely broker-agnostic.
class CdpConfig {
  const CdpConfig({this.host = '127.0.0.1', this.port = 9222});

  final String host;
  final int port;

  factory CdpConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const CdpConfig();
    return CdpConfig(
      host: json['host'] as String? ?? '127.0.0.1',
      port: (json['port'] as num?)?.toInt() ?? 9222,
    );
  }

  Map<String, dynamic> toJson() => {'host': host, 'port': port};
}

class RiskConfig {
  const RiskConfig({
    this.dailyLossLimitPct = 5,
    this.maxPositions = 3,
    this.maxPerSymbol = 1,
    this.maxTradeSizePct = 2,
    this.cooldownSec = 900,
  });

  final double dailyLossLimitPct;
  final int maxPositions;
  final int maxPerSymbol;
  final double maxTradeSizePct;
  final int cooldownSec;

  factory RiskConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const RiskConfig();
    return RiskConfig(
      dailyLossLimitPct:
          (json['daily_loss_limit_pct'] as num?)?.toDouble() ?? 5,
      maxPositions: (json['max_positions'] as num?)?.toInt() ?? 3,
      maxPerSymbol: (json['max_per_symbol'] as num?)?.toInt() ?? 1,
      maxTradeSizePct: (json['max_trade_size_pct'] as num?)?.toDouble() ?? 2,
      cooldownSec: (json['cooldown_sec'] as num?)?.toInt() ?? 900,
    );
  }

  Map<String, dynamic> toJson() => {
    'daily_loss_limit_pct': dailyLossLimitPct,
    'max_positions': maxPositions,
    'max_per_symbol': maxPerSymbol,
    'max_trade_size_pct': maxTradeSizePct,
    'cooldown_sec': cooldownSec,
  };
}

class TechniqueConfig {
  const TechniqueConfig({this.rangeSwingCount = 20});

  final int rangeSwingCount;

  factory TechniqueConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const TechniqueConfig();
    return TechniqueConfig(
      rangeSwingCount: (json['range_swing_count'] as num?)?.toInt() ?? 20,
    );
  }

  Map<String, dynamic> toJson() => {'range_swing_count': rangeSwingCount};
}

/// One tradable symbol: which TradingView chart symbol supplies the signal
/// (e.g. `BTCUSDT`) and which exact MT5 broker symbol executes the
/// trade (e.g. `BTCUSD.lv` — Equiti's own naming, confirmed live 2026-09-17
/// via `get_marketwatch_symbols`; MT5 symbol naming is broker-specific and
/// does NOT generally match TradingView's, so this mapping is explicit
/// rather than derived).
///
/// **Naming rule, per the user (2026-09-17)**: MT5 has no USDT — every
/// crypto pair uses USD instead (e.g. TradingView `BTCUSDT` ->
/// MT5 `BTCUSD` + this broker's `.lv` suffix). Forex and stock symbols are
/// unaffected — they're already USD-quoted on both sides, so the name
/// typically doesn't change. Always confirm the exact broker symbol via
/// `Mt5Client.getMarketWatchSymbol` before adding an entry here — don't
/// assume the rule mechanically produces a valid symbol name.
class SymbolMapping {
  const SymbolMapping({required this.tradingViewSymbol, required this.mt5Symbol});

  final String tradingViewSymbol;
  final String mt5Symbol;

  factory SymbolMapping.fromJson(Map<String, dynamic> json) => SymbolMapping(
    tradingViewSymbol: json['tradingview_symbol'] as String,
    mt5Symbol: json['mt5_symbol'] as String,
  );

  Map<String, dynamic> toJson() => {
    'tradingview_symbol': tradingViewSymbol,
    'mt5_symbol': mt5Symbol,
  };
}

class AppConfig {
  const AppConfig({
    this.pollIntervalSec = 5,
    this.remoteSession = true,
    this.mt5 = const Mt5Config(),
    this.cdp = const CdpConfig(),
    this.technique = const TechniqueConfig(),
    this.risk = const RiskConfig(),
    this.symbols = const [],
    this.heartbeatAlertEveryMin = 15,
  });

  final int pollIntervalSec;

  /// Same reasoning as tradingPionex's identical field: keeps TradingView on
  /// the isolated, invisible display by default (the safe default) rather
  /// than guessing from session info — flip to false in Settings only when
  /// you know you're on a normal, non-remote desktop session.
  final bool remoteSession;
  final Mt5Config mt5;
  final CdpConfig cdp;
  final TechniqueConfig technique;
  final RiskConfig risk;
  final List<SymbolMapping> symbols;
  final int heartbeatAlertEveryMin;

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
    pollIntervalSec: (json['poll_interval_sec'] as num?)?.toInt() ?? 5,
    remoteSession: json['remote_session'] as bool? ?? true,
    mt5: Mt5Config.fromJson(json['mt5'] as Map<String, dynamic>?),
    cdp: CdpConfig.fromJson(json['cdp'] as Map<String, dynamic>?),
    technique: TechniqueConfig.fromJson(
      json['technique'] as Map<String, dynamic>?,
    ),
    risk: RiskConfig.fromJson(json['risk'] as Map<String, dynamic>?),
    symbols: ((json['symbols'] as List?) ?? const [])
        .map((e) => SymbolMapping.fromJson(e as Map<String, dynamic>))
        .toList(),
    heartbeatAlertEveryMin:
        (json['heartbeat']?['alert_every_min'] as num?)?.toInt() ?? 15,
  );

  Map<String, dynamic> toJson() => {
    'poll_interval_sec': pollIntervalSec,
    'remote_session': remoteSession,
    'mt5': mt5.toJson(),
    'cdp': cdp.toJson(),
    'technique': technique.toJson(),
    'risk': risk.toJson(),
    'symbols': symbols.map((e) => e.toJson()).toList(),
    'heartbeat': {'alert_every_min': heartbeatAlertEveryMin},
  };

  static const defaultConfig = AppConfig(
    symbols: [
      SymbolMapping(tradingViewSymbol: 'BTCUSDT', mt5Symbol: 'BTCUSD.lv'),
    ],
  );
}
