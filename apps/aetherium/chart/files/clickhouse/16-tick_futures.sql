-- tick_futures: the futures' trades, in the shape every consumer reads (kbar-tick-agg,
-- replay-segments, hindsight) — MoneyDJ's symbols, prices × 100, its direction codes — across the
-- cutover. The switch is at 2026-10-22 06:00 Taiwan time, a day before the cutover itself: the
-- typhoon closure of 10-23 skipped the morning job that would have fetched MoneyDJ's 10-22 night
-- session, while Shioaji has both of that day's sessions.
--   before: MoneyDJ's replay (tick_futures_mdj)
--   after:  Shioaji's API (tick_fut_sj, market-tap's amt-futures). Per (product, contract, session)
--           the history if there is one (written after the day session, for the night before and
--           the day), else the stream without the pre-open trial matches.
-- A session is keyed by its times, not by Shioaji's trade_date: the stream dates a night session by
-- the calendar when it starts, the history by the exchange's, and a holiday added in between makes
-- them differ (the night of 2026-10-22 is 10-23 in the stream). Its key, in Taiwan time (UTC+8, no
-- daylight saving time) less 6 hours: the date it opens on, and whether it's the night one (day
-- 02:30–07:45, night 08:50–23:00).
-- That filter is in a subquery: in the outer SELECT symbol and trade_date are the converted values'
-- aliases, and ClickHouse's WHERE would read those.
-- Mapping, from the parallel run of 2026-10-19..21: MoneyDJ's price = Shioaji's × 100; direction
-- 1 = 內盤 = tick_type 2, 2 = 外盤 = tick_type 1 (about 11% of trades disagreed: MoneyDJ seems to
-- infer it, Shioaji's is the exchange's). trade_date is MoneyDJ's: the day the session opens on.
-- MoneyDJ's mark_bias and cumulative match quantities have no counterpart: 0.
CREATE OR REPLACE VIEW tick_futures AS
SELECT ts, symbol, trade_date, price, bid, ask, volume, total_volume, direction,
       mark_bias, buy_match_qty, sell_match_qty, seq
FROM tick_futures_mdj
WHERE ts < toDateTime('2026-10-21 22:00:00', 'UTC')
UNION ALL
SELECT
    CAST(ts AS DateTime) AS ts,
    transform(symbol, ['TXF', 'MXF', 'TMF'], ['FITXN*1.TF', 'FIMTXN*1.TF', 'FITMN*1.TF'], symbol) AS symbol,
    toUInt32(toYYYYMMDD(toDate(ts + INTERVAL 8 HOUR - INTERVAL 6 HOUR))) AS trade_date,
    toUInt32(round(price * 100)) AS price,
    toUInt32(round(bid * 100)) AS bid,
    toUInt32(round(ask * 100)) AS ask,
    volume,
    total_volume,
    toUInt8(transform(tick_type, [1, 2], [2, 1], 0)) AS direction,
    toInt32(0) AS mark_bias,
    toUInt32(0) AS buy_match_qty,
    toUInt32(0) AS sell_match_qty,
    seq
FROM
(
    SELECT *
    FROM tick_fut_sj
    WHERE ts >= toDateTime64('2026-10-21 22:00:00', 6, 'UTC')
      AND (origin = 'hist'
           OR (origin = 'stream' AND simtrade = 0
               AND (symbol, contract, toDate(ts + INTERVAL 2 HOUR), toHour(ts + INTERVAL 2 HOUR) >= 8) NOT IN
                   (SELECT DISTINCT symbol, contract, toDate(ts + INTERVAL 2 HOUR), toHour(ts + INTERVAL 2 HOUR) >= 8
                    FROM tick_fut_sj
                    WHERE origin = 'hist')))
)
