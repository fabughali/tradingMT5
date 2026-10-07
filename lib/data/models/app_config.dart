/// Broker connection settings for MT5's native MCP server (build 6140+) —
/// see ARCHITECTURE.md for why this was chosen over an MQL5-EA/file bridge
/// or WebTerminal automation. Auth key lives in `.env` (MT5_MCP_API_KEY),
/// never here.
class Mt5Config {
  const Mt5Config({required this.mcpHost, required this.mcpPort});

  final String mcpHost;
  final int mcpPort;

  /// No fallback host/port (2026-10-07, per the user: this app is now a
  /// public repo - every user has their own MT5 MCP setup, not this one's,
  /// so nothing here should silently assume a value for them). See
  /// `config.example.json` for what to actually put in `mt5.mcp_host`/
  /// `mt5.mcp_port` - typically `127.0.0.1` and whatever port MT5's own
  /// Tools > Options > MCP page shows, which can differ per install.
  factory Mt5Config.fromJson(Map<String, dynamic>? json) {
    final host = json?['mcp_host'] as String?;
    final port = (json?['mcp_port'] as num?)?.toInt();
    if (host == null || port == null) {
      throw const FormatException(
        'config.json is missing "mt5.mcp_host"/"mt5.mcp_port" - see '
        'config.example.json for what to fill in (your own MT5 MCP '
        'host/port, from Tools > Options > MCP in the terminal).',
      );
    }
    return Mt5Config(mcpHost: host, mcpPort: port);
  }

  Map<String, dynamic> toJson() => {'mcp_host': mcpHost, 'mcp_port': mcpPort};
}

/// TradingView Desktop's Chrome DevTools Protocol debug port — the same
/// signal-reading connection tradingPionex uses, ported unchanged since
/// signal reading is entirely broker-agnostic.
class CdpConfig {
  const CdpConfig({required this.host, required this.port});

  final String host;
  final int port;

  /// No fallback host/port - same reasoning as [Mt5Config.fromJson]'s own
  /// doc comment. See `config.example.json` for `cdp.host`/`cdp.port`
  /// (typically `127.0.0.1` and `9222`, TradingView Desktop's remote
  /// debugging port - but confirm against your own launch flags).
  factory CdpConfig.fromJson(Map<String, dynamic>? json) {
    final host = json?['host'] as String?;
    final port = (json?['port'] as num?)?.toInt();
    if (host == null || port == null) {
      throw const FormatException(
        'config.json is missing "cdp.host"/"cdp.port" - see '
        'config.example.json for what to fill in.',
      );
    }
    return CdpConfig(host: host, port: port);
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
    required this.mt5,
    required this.cdp,
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

  /// Seeds a FRESH config.json on first run only ([loadOrInitConfig]) - a
  /// plain, editable starter file in the user's own local data directory,
  /// never committed/public. `127.0.0.1` + these specific ports are just
  /// the common case for a local MT5/TradingView setup, not a real
  /// user's specific values - edit mt5/cdp here (or in the written file
  /// directly) to match your own, same as `config.example.json`.
  static const defaultConfig = AppConfig(
    mt5: Mt5Config(mcpHost: '127.0.0.1', mcpPort: 22346),
    cdp: CdpConfig(host: '127.0.0.1', port: 9222),
    symbols: [
      SymbolMapping(tradingViewSymbol: 'BTCUSDT', mt5Symbol: 'BTCUSD.lv'),
    ],
  );
}
