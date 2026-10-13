-- Stock trades (amt tick, uploaded as JSONEachRow with ts as epoch seconds).
-- Rebuilt: market-tap's repo doesn't have this table's DDL. Columns from its upload code
-- (src/upload/tick.rs), codecs and partitioning as tick_futures. ts is DateTime: the monthly
-- archive filters it with toYYYYMM(ts), and hindsight, which treats it as epoch seconds (UInt32),
-- reads and compares a DateTime the same way. Compare with SHOW CREATE TABLE on the old server
-- before importing; an INSERT ... SELECT converts UInt32 seconds to DateTime by itself.
CREATE TABLE IF NOT EXISTS tick_data
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
