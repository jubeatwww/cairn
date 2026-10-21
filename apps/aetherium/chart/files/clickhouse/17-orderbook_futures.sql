-- orderbook_futures: the futures' five-level books, in the shape every consumer reads
-- (replay-segments, hindsight) — MoneyDJ's symbols and columns, prices × 100 — across the
-- 2026-10-24 cutover (06:00 Taiwan time, between two sessions):
--   before: MoneyDJ's web feed (orderbook_futures_mdj), sparse: a column a push didn't carry is 0
--   after:  Shioaji's API (book_fut_sj, market-tap's amt-futures), every row a full book, the
--           pre-open trial-match books included (MoneyDJ's had them too)
-- Reading 0 as "same as the previous row" works for both. The open interest isn't here after the
-- cutover (0): it's in futures_oi, from MoneyDJ. Its other columns (settlement and OHLC quotes,
-- order counts, match quantities) have no counterpart in Shioaji's books: 0.
-- IF NOT EXISTS, not OR REPLACE as for the other views: until the cutover a table had this name.
-- Changing the view is a manual CREATE OR REPLACE VIEW.
CREATE VIEW IF NOT EXISTS orderbook_futures AS
SELECT
    ts, symbol,
    bid1, bid2, bid3, bid4, bid5, bid1_vol, bid2_vol, bid3_vol, bid4_vol, bid5_vol,
    ask1, ask2, ask3, ask4, ask5, ask1_vol, ask2_vol, ask3_vol, ask4_vol, ask5_vol,
    open_interest, oi_change, settlement_price, prev_close, open_price, high_price, low_price,
    mark_bias, bid_order_count, bid_order_size, ask_order_count, ask_order_size,
    buy_match_qty, sell_match_qty
FROM orderbook_futures_mdj
WHERE ts < toDateTime64('2026-10-23 22:00:00', 3, 'UTC')
UNION ALL
SELECT
    CAST(ts AS DateTime64(3)) AS ts,
    transform(symbol, ['TXF', 'MXF', 'TMF'], ['FITXN*1.TF', 'FIMTXN*1.TF', 'FITMN*1.TF'], symbol) AS symbol,
    toUInt32(round(bid1 * 100)) AS bid1, toUInt32(round(bid2 * 100)) AS bid2,
    toUInt32(round(bid3 * 100)) AS bid3, toUInt32(round(bid4 * 100)) AS bid4,
    toUInt32(round(bid5 * 100)) AS bid5,
    bid1_vol, bid2_vol, bid3_vol, bid4_vol, bid5_vol,
    toUInt32(round(ask1 * 100)) AS ask1, toUInt32(round(ask2 * 100)) AS ask2,
    toUInt32(round(ask3 * 100)) AS ask3, toUInt32(round(ask4 * 100)) AS ask4,
    toUInt32(round(ask5 * 100)) AS ask5,
    ask1_vol, ask2_vol, ask3_vol, ask4_vol, ask5_vol,
    toUInt32(0) AS open_interest, toInt32(0) AS oi_change, toUInt32(0) AS settlement_price,
    toUInt32(0) AS prev_close, toUInt32(0) AS open_price, toUInt32(0) AS high_price,
    toUInt32(0) AS low_price, toInt32(0) AS mark_bias,
    toUInt32(0) AS bid_order_count, toUInt32(0) AS bid_order_size,
    toUInt32(0) AS ask_order_count, toUInt32(0) AS ask_order_size,
    toUInt32(0) AS buy_match_qty, toUInt32(0) AS sell_match_qty
FROM book_fut_sj
WHERE ts >= toDateTime64('2026-10-23 22:00:00', 6, 'UTC')
