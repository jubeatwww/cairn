-- From market-tap's docs/futures-schema.sql.
CREATE TABLE IF NOT EXISTS tick_futures
(
    ts             DateTime                CODEC(Delta(4), ZSTD(3)),
    symbol         LowCardinality(String)  CODEC(ZSTD(3)),
    trade_date     UInt32                  CODEC(ZSTD(3)),            -- V535
    price          UInt32                  CODEC(Delta(4), ZSTD(3)),  -- V48
    bid            UInt32                  CODEC(Delta(4), ZSTD(3)),  -- V49
    ask            UInt32                  CODEC(Delta(4), ZSTD(3)),  -- V50
    volume         UInt32                  CODEC(ZSTD(3)),            -- V51
    total_volume   UInt32                  CODEC(Delta(4), ZSTD(3)),  -- V52
    direction      UInt8                   CODEC(ZSTD(3)),            -- V53
    mark_bias      Int32                   CODEC(Delta(4), ZSTD(3)),  -- V66
    buy_match_qty  UInt32                  CODEC(Delta(4), ZSTD(3)),  -- V122
    sell_match_qty UInt32                  CODEC(Delta(4), ZSTD(3)),  -- V123
    seq            UInt32                  CODEC(Delta(4), ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (symbol, ts, seq)
SETTINGS index_granularity = 8192
