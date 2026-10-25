-- The stocks' trades from MoneyDJ's post-market replay as amt-server uploaded them, until market-tap's
-- P3; it was named tick_data, which is now the view across this and market_trades
-- (19-tick_data.sql). Rebuilt: market-tap's repo didn't have this table's DDL. Columns from its
-- upload code then (src/upload/tick.rs), codecs and partitioning as tick_futures. ts is DateTime:
-- the monthly archive filters it with toYYYYMM(ts), and hindsight, which treats it as epoch seconds
-- (UInt32), reads and compares a DateTime the same way.
CREATE TABLE IF NOT EXISTS tick_data_mdj
(
    ts        DateTime               CODEC(Delta(4), ZSTD(3)),
    symbol    LowCardinality(String) CODEC(ZSTD(3)),
    price     UInt32                 CODEC(Delta(4), ZSTD(3)),
    bid       UInt32                 CODEC(Delta(4), ZSTD(3)),
    ask       UInt32                 CODEC(Delta(4), ZSTD(3)),
    volume    UInt32                 CODEC(ZSTD(3)),
    direction UInt8                  CODEC(ZSTD(3)),
    seq       UInt32                 CODEC(Delta(4), ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (symbol, ts, seq)
SETTINGS index_granularity = 8192
