-- The stocks' trades in the shape their readers have always had — MoneyDJ's symbols (2330.TW),
-- prices × 100, volume in lots, MoneyDJ's direction (1 = 內盤, 2 = 外盤) — across market-tap's P3,
-- when amt-server started handing its post-market replay to amt-collector:
--   before: tick_data_mdj, as uploaded
--   after:  market_trades (asset 'stock', source 'moneydj', origin 'hist')
-- No cut-off time, as for orderbook (18-orderbook.sql). Fubon's trades (source 'fubon') aren't here
-- until they're compared with MoneyDJ's and replace them (market-tap's P1 switch).
CREATE OR REPLACE VIEW tick_data AS
SELECT ts, symbol, price, bid, ask, volume, direction, seq
FROM tick_data_mdj
UNION ALL
SELECT
    CAST(ts AS DateTime) AS ts,
    concat(symbol, '.TW') AS symbol,
    toUInt32(round(price * 100)) AS price,
    toUInt32(round(bid * 100)) AS bid,
    toUInt32(round(ask * 100)) AS ask,
    intDiv(qty, 1000) AS volume,
    toUInt8(transform(side, [1, 2], [2, 1], 0)) AS direction,
    toUInt32(seq) AS seq
FROM market_trades
WHERE asset = 'stock' AND source = 'moneydj' AND origin = 'hist'
