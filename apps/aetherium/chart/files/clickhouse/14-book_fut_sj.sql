-- The futures' five-level books from Shioaji's API (market-tap's amt-futures), since 2026-10-19:
-- every row a full book, prices in index points. amt-futures creates this table itself; it's here
-- too so that 17-orderbook_futures.sql can be created on a fresh install. Copied from market-tap's
-- futures/amt_futures/schema.py (BOOK_DDL): keep the two the same.
CREATE TABLE IF NOT EXISTS book_fut_sj
(
    ts              DateTime64(6, 'UTC')   CODEC(Delta(8), ZSTD(3)),
    trade_date      Date                   CODEC(ZSTD(3)),
    symbol          LowCardinality(String) CODEC(ZSTD(3)),
    contract        LowCardinality(String) CODEC(ZSTD(3)),
    seq             UInt64                 CODEC(Delta(8), ZSTD(3)),    -- 進程內遞增,同一微秒多筆時定序
    bid1 Float64 CODEC(ZSTD(3)), bid2 Float64 CODEC(ZSTD(3)), bid3 Float64 CODEC(ZSTD(3)), bid4 Float64 CODEC(ZSTD(3)), bid5 Float64 CODEC(ZSTD(3)),
    bid1_vol UInt32 CODEC(ZSTD(3)), bid2_vol UInt32 CODEC(ZSTD(3)), bid3_vol UInt32 CODEC(ZSTD(3)), bid4_vol UInt32 CODEC(ZSTD(3)), bid5_vol UInt32 CODEC(ZSTD(3)),
    ask1 Float64 CODEC(ZSTD(3)), ask2 Float64 CODEC(ZSTD(3)), ask3 Float64 CODEC(ZSTD(3)), ask4 Float64 CODEC(ZSTD(3)), ask5 Float64 CODEC(ZSTD(3)),
    ask1_vol UInt32 CODEC(ZSTD(3)), ask2_vol UInt32 CODEC(ZSTD(3)), ask3_vol UInt32 CODEC(ZSTD(3)), ask4_vol UInt32 CODEC(ZSTD(3)), ask5_vol UInt32 CODEC(ZSTD(3)),
    bid_total_vol   UInt32                 CODEC(ZSTD(3)),
    ask_total_vol   UInt32                 CODEC(ZSTD(3)),
    derived_bid     Float64                CODEC(ZSTD(3)),             -- 價差單衍生最佳一檔
    derived_bid_vol UInt32                 CODEC(ZSTD(3)),
    derived_ask     Float64                CODEC(ZSTD(3)),
    derived_ask_vol UInt32                 CODEC(ZSTD(3)),
    underlying      Float64                CODEC(ZSTD(3)),
    simtrade        UInt8                  CODEC(ZSTD(3)),
    ingested_at     DateTime64(3, 'UTC')   DEFAULT now64(3) CODEC(ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(trade_date)
ORDER BY (symbol, ts, seq)
SETTINGS non_replicated_deduplication_window = 1000
