-- The futures' order books from MoneyDJ's web feed, up to the 2026-10-23 cutover; it was named
-- orderbook_futures, which is now the view that consumers read (17-orderbook_futures.sql). Since
-- then the books come from amt-futures (book_fut_sj) and MoneyDJ only gives the open interest
-- (futures_oi). From market-tap's docs/futures-schema.sql (column rationale and V-field mapping:
-- docs/futures-design.md); sparse: a column a push didn't carry is 0.
CREATE TABLE IF NOT EXISTS orderbook_futures_mdj
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
    ask5_vol UInt32               CODEC(ZSTD(3)),

    open_interest UInt32          CODEC(Delta(4), ZSTD(3)),  -- V37
    oi_change Int32               CODEC(ZSTD(3)),            -- V38
    settlement_price UInt32       CODEC(Delta(4), ZSTD(3)),  -- V39

    prev_close UInt32             CODEC(Delta(4), ZSTD(3)),  -- V6
    open_price UInt32             CODEC(Delta(4), ZSTD(3)),  -- V7
    high_price UInt32             CODEC(Delta(4), ZSTD(3)),  -- V8
    low_price  UInt32             CODEC(Delta(4), ZSTD(3)),  -- V9

    mark_bias Int32               CODEC(Delta(4), ZSTD(3)),  -- V66
    bid_order_count UInt32        CODEC(Delta(4), ZSTD(3)),  -- V40
    bid_order_size  UInt32        CODEC(Delta(4), ZSTD(3)),  -- V41
    ask_order_count UInt32        CODEC(Delta(4), ZSTD(3)),  -- V42
    ask_order_size  UInt32        CODEC(Delta(4), ZSTD(3)),  -- V43
    buy_match_qty   UInt32        CODEC(Delta(4), ZSTD(3)),  -- V122
    sell_match_qty  UInt32        CODEC(Delta(4), ZSTD(3))   -- V123
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (symbol, ts)
SETTINGS index_granularity = 8192
