-- The futures' trades from Shioaji's API as market-tap's amt-futures wrote them from 2026-10-19 until
-- it moved to amt-collector (market-tap's P2), which copied them into market_trades: origin 'stream'
-- as collected, 'hist' from Shioaji's history after the day session. Nothing writes or reads it
-- since; it goes, with this file, once that's confirmed. Copied from amt-futures' DDL before P2
-- (market-tap's futures/amt_futures/schema.py, TICK_DDL).
CREATE TABLE IF NOT EXISTS tick_fut_sj
(
    ts                 DateTime64(6, 'UTC')   CODEC(Delta(8), ZSTD(3)),
    trade_date         Date                   CODEC(ZSTD(3)),
    symbol             LowCardinality(String) CODEC(ZSTD(3)),
    contract           LowCardinality(String) CODEC(ZSTD(3)),
    origin             LowCardinality(String) CODEC(ZSTD(3)),
    seq                UInt32                 CODEC(Delta(4), ZSTD(3)),
    price              Float64                CODEC(ZSTD(3)),
    volume             UInt32                 CODEC(ZSTD(3)),
    tick_type          UInt8                  CODEC(ZSTD(3)),             -- 1 外盤 / 2 內盤 / 0 不明
    bid                Float64                CODEC(ZSTD(3)),             -- stream:當下最新五檔的最佳買
    ask                Float64                CODEC(ZSTD(3)),
    bid_volume         UInt32                 CODEC(ZSTD(3)),
    ask_volume         UInt32                 CODEC(ZSTD(3)),
    total_volume       UInt32                 CODEC(Delta(4), ZSTD(3)),   -- stream only
    underlying         Float64                CODEC(ZSTD(3)),             -- stream only,夜盤凍結
    bid_side_total_vol UInt32                 CODEC(Delta(4), ZSTD(3)),   -- stream only,累積內盤口數
    ask_side_total_vol UInt32                 CODEC(Delta(4), ZSTD(3)),   -- stream only,累積外盤口數
    simtrade           UInt8                  CODEC(ZSTD(3)),             -- 1 = 試撮
    ingested_at        DateTime64(3, 'UTC')   DEFAULT now64(3) CODEC(ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(trade_date)
ORDER BY (symbol, trade_date, origin, ts, seq)
SETTINGS non_replicated_deduplication_window = 1000
