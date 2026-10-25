-- Every source's five-level books in one shape, futures and stocks: written by market-tap's
-- amt-collector only, like 15a-market_trades.sql. Each row is a whole book, empty levels 0.
-- Copied from market-tap's schema/market.sql: keep the two the same.
CREATE TABLE IF NOT EXISTS market_quotes
(
    ts          DateTime64(6, 'UTC')                  CODEC(Delta(8), ZSTD(3)),
    trade_date  Date                                  CODEC(ZSTD(3)),
    asset       LowCardinality(String)                CODEC(ZSTD(3)),
    symbol      LowCardinality(String)                CODEC(ZSTD(3)),
    contract    LowCardinality(String)                CODEC(ZSTD(3)),
    source      LowCardinality(String)                CODEC(ZSTD(3)),
    origin      LowCardinality(String)                CODEC(ZSTD(3)),
    session     LowCardinality(String)                CODEC(ZSTD(3)),
    seq         UInt64                                CODEC(Delta(8), ZSTD(3)),
    bid1        Decimal64(4)                          CODEC(ZSTD(3)),
    bid2        Decimal64(4)                          CODEC(ZSTD(3)),
    bid3        Decimal64(4)                          CODEC(ZSTD(3)),
    bid4        Decimal64(4)                          CODEC(ZSTD(3)),
    bid5        Decimal64(4)                          CODEC(ZSTD(3)),
    bid1_qty    UInt32                                CODEC(ZSTD(3)),
    bid2_qty    UInt32                                CODEC(ZSTD(3)),
    bid3_qty    UInt32                                CODEC(ZSTD(3)),
    bid4_qty    UInt32                                CODEC(ZSTD(3)),
    bid5_qty    UInt32                                CODEC(ZSTD(3)),
    ask1        Decimal64(4)                          CODEC(ZSTD(3)),
    ask2        Decimal64(4)                          CODEC(ZSTD(3)),
    ask3        Decimal64(4)                          CODEC(ZSTD(3)),
    ask4        Decimal64(4)                          CODEC(ZSTD(3)),
    ask5        Decimal64(4)                          CODEC(ZSTD(3)),
    ask1_qty    UInt32                                CODEC(ZSTD(3)),
    ask2_qty    UInt32                                CODEC(ZSTD(3)),
    ask3_qty    UInt32                                CODEC(ZSTD(3)),
    ask4_qty    UInt32                                CODEC(ZSTD(3)),
    ask5_qty    UInt32                                CODEC(ZSTD(3)),
    trial       UInt8                                 CODEC(ZSTD(3)),
    extra       Map(LowCardinality(String), Float64)  CODEC(ZSTD(3)),
    ingested_at DateTime64(3, 'UTC') DEFAULT now64(3) CODEC(ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY (asset, toYYYYMM(trade_date))
ORDER BY (symbol, trade_date, source, ts, seq)
SETTINGS non_replicated_deduplication_window = 1000
