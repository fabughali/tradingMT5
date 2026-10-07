# trading_mt5

TradingMT5: deterministic MT5-broker grid/signal trading engine
(Flutter/Dart), standalone with TradingView and MetaTrader 5.

100% independent from `tradingPionex` — own engine, own runtime state, own
memory. `tradingPionex` is consulted read-only for its proven architecture
pattern and hard-won bug lessons. See `ARCHITECTURE.md` for the full design
and `GAPS.md` for open questions.

## Running

```
cp .env.example ~/.tradingmt5/.env      # fill in MT5_MCP_API_KEY
flutter run -d linux                    # GUI
dart run bin/engine.dart                # headless engine (separate terminal)
```

Data directory defaults to `~/.tradingmt5` (override with `TRADING_MT5_HOME`).
