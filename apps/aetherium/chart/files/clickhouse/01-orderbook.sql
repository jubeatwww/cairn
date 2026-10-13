-- Stock five-level order book, one row per update (amt orderbook, uploaded as JSONEachRow).
-- Rebuilt: market-tap's repo doesn't have this table's DDL. Columns from its upload code
-- (src/upload/orderbook.rs), codecs and partitioning as orderbook_futures, which copied them from
-- here (docs/futures-design.md). Compare with SHOW CREATE TABLE on the old server before importing.
CREATE TABLE IF NOT EXISTS orderbook
(
    ts DateTime64(3)              CODEC(Delta(8), ZSTD(3)),
    symbol LowCardinality(String) CODEC(ZSTD(3)),

    bid1 UInt32                   CODEC(Delta(4), ZSTD(3)),
    bid2 UInt32                   CODEC(Delta(4), ZSTD(3)),
    bid3 UInt32                   CODEC(Delta(4), ZSTD(3)),
    bid4 UInt32                   CODEC(Delta(4), ZSTD(3)),
    bid5 UInt32                   CODEC(Delta(4), ZSTD(3)),
    bid1_vol UInt32               CODEC(ZSTD(3)),
    bid2_vol UInt32               CODEC(ZSTD(3)),
    bid3_vol UInt32               CODEC(ZSTD(3)),
    bid4_vol UInt32               CODEC(ZSTD(3)),
    bid5_vol UInt32               CODEC(ZSTD(3)),
    ask1 UInt32                   CODEC(Delta(4), ZSTD(3)),
    ask2 UInt32                   CODEC(Delta(4), ZSTD(3)),
    ask3 UInt32                   CODEC(Delta(4), ZSTD(3)),
    ask4 UInt32                   CODEC(Delta(4), ZSTD(3)),
    ask5 UInt32                   CODEC(Delta(4), ZSTD(3)),
    ask1_vol UInt32               CODEC(ZSTD(3)),
    ask2_vol UInt32               CODEC(ZSTD(3)),
    ask3_vol UInt32               CODEC(ZSTD(3)),
    ask4_vol UInt32               CODEC(ZSTD(3)),
    ask5_vol UInt32               CODEC(ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (symbol, ts)
SETTINGS index_granularity = 8192
