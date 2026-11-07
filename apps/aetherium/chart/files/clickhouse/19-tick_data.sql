-- The stocks' trades in the shape their readers have always had — MoneyDJ's symbols (2330.TW),
-- prices × 100, volume in lots, MoneyDJ's direction (1 = 內盤, 2 = 外盤):
--   before market-tap's P3: tick_data_mdj, as uploaded
--   to 2026-10-27:          market_trades from MoneyDJ (source 'moneydj'), amt-server's post-market
--                           replay at 14:45
--   from 2026-10-28:        market_trades from Shioaji (source 'sinopac', regular session),
--                           amt-sinopac-stock-trades' pass the next morning
-- From 10-28 on, Shioaji's trades equal MoneyDJ's in count and shares for every stock both have,
-- and add about 35 stocks MoneyDJ lacks (TDRs among them) and the trades MoneyDJ lost on 11-05; the
-- direction agrees for 99.8%. Their bid/ask is the best quote after the trade, MoneyDJ's the one
-- the trade took. A day shows up after the next morning's pass. Fubon's trades (source 'fubon')
-- aren't here: its history drops trades around busy opens.
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
WHERE asset = 'stock' AND origin = 'hist' AND session = 'regular'
    AND (source = 'moneydj' AND trade_date < '2026-10-28'
        OR source = 'sinopac' AND trade_date >= '2026-10-28')
