-- The stocks' books in the shape their readers have always had — MoneyDJ's symbols (2330.TW),
-- prices × 100, sizes in lots — across market-tap's P3, when amt-server started handing them to
-- amt-collector:
--   before: orderbook_mdj, as uploaded, sparse: a column a push didn't carry is 0
--   after:  market_quotes (asset 'stock', source 'moneydj'), every row the whole book
-- Reading 0 as "same as the previous row" works for both. No cut-off time: nothing writes the old
-- table since, and nothing wrote MoneyDJ's books into market_quotes before (P3 went live on a day
-- without a session).
CREATE OR REPLACE VIEW orderbook AS
SELECT
    ts, symbol,
    bid1, bid2, bid3, bid4, bid5, bid1_vol, bid2_vol, bid3_vol, bid4_vol, bid5_vol,
    ask1, ask2, ask3, ask4, ask5, ask1_vol, ask2_vol, ask3_vol, ask4_vol, ask5_vol
FROM orderbook_mdj
UNION ALL
SELECT
    CAST(ts AS DateTime64(3)) AS ts,
    concat(symbol, '.TW') AS symbol,
    toUInt32(round(bid1 * 100)) AS bid1, toUInt32(round(bid2 * 100)) AS bid2,
    toUInt32(round(bid3 * 100)) AS bid3, toUInt32(round(bid4 * 100)) AS bid4,
    toUInt32(round(bid5 * 100)) AS bid5,
    intDiv(bid1_qty, 1000) AS bid1_vol, intDiv(bid2_qty, 1000) AS bid2_vol,
    intDiv(bid3_qty, 1000) AS bid3_vol, intDiv(bid4_qty, 1000) AS bid4_vol,
    intDiv(bid5_qty, 1000) AS bid5_vol,
    toUInt32(round(ask1 * 100)) AS ask1, toUInt32(round(ask2 * 100)) AS ask2,
    toUInt32(round(ask3 * 100)) AS ask3, toUInt32(round(ask4 * 100)) AS ask4,
    toUInt32(round(ask5 * 100)) AS ask5,
    intDiv(ask1_qty, 1000) AS ask1_vol, intDiv(ask2_qty, 1000) AS ask2_vol,
    intDiv(ask3_qty, 1000) AS ask3_vol, intDiv(ask4_qty, 1000) AS ask4_vol,
    intDiv(ask5_qty, 1000) AS ask5_vol
FROM market_quotes
WHERE asset = 'stock' AND source = 'moneydj'
