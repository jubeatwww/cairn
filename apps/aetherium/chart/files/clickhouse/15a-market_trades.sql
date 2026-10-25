-- Every source's trades in one shape, futures and stocks: written by market-tap's amt-collector
-- only, which the providers hand them to (market-tap's docs/collector-design.md). origin 'stream' as
-- collected, 'hist' from a source's complete post-session data. Missing values are 0 or '' (no
-- Nullable); prices as quoted, qty in shares for stocks and contracts for futures; side 1 for the
-- buyer's initiative, 2 the seller's, 0 when the source doesn't say. Copied from market-tap's
-- schema/market.sql: keep the two the same. The collector doesn't create it, only checks its
-- columns when it starts (AmtCollectorSchemaMismatch).
CREATE TABLE IF NOT EXISTS market_trades
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
    price       Decimal64(4)                          CODEC(ZSTD(3)),
    qty         UInt32                                CODEC(ZSTD(3)),
    side        UInt8                                 CODEC(ZSTD(3)),
    bid         Decimal64(4)                          CODEC(ZSTD(3)),
    ask         Decimal64(4)                          CODEC(ZSTD(3)),
    trial       UInt8                                 CODEC(ZSTD(3)),
    extra       Map(LowCardinality(String), Float64)  CODEC(ZSTD(3)),
    ingested_at DateTime64(3, 'UTC') DEFAULT now64(3) CODEC(ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY (asset, toYYYYMM(trade_date))
ORDER BY (symbol, trade_date, source, origin, ts, seq)
SETTINGS non_replicated_deduplication_window = 1000
