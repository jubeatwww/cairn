-- The futures' intraday open interest, from MoneyDJ's web feed in both sessions: one row per push
-- that carried it (market-tap's src/upload/futures_oi.rs). No API has it, so it's what that feed
-- still collects of the futures after the 2026-10-23 cutover; the rows before then were copied over
-- from orderbook_futures_mdj. ts is when it was received.
CREATE TABLE IF NOT EXISTS futures_oi
(
    ts            DateTime64(3)          CODEC(Delta(8), ZSTD(3)),
    symbol        LowCardinality(String) CODEC(ZSTD(3)),             -- TXF / MXF / TMF
    open_interest UInt32                 CODEC(Delta(4), ZSTD(3)),   -- V37; 0 = not in this push
    oi_change     Int32                  CODEC(ZSTD(3))              -- V38
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (symbol, ts)
