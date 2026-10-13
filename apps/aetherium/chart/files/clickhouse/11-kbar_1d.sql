-- From market-tap's docs/kbar-schema.sql.
-- 日 K = 日盤限定(08:45~13:45),與期交所官方日行情同義;全日盤版有需要再加。
CREATE OR REPLACE VIEW kbar_1d AS
SELECT
    toDate(ts - INTERVAL 1 MINUTE + INTERVAL 8 HOUR) AS trade_date, symbol,
    argMin(open, ts) AS open, max(high) AS high, min(low) AS low, argMax(close, ts) AS close,
    sum(volume) AS volume, sum(amount) AS amount
FROM kbar_1m_canonical
WHERE toHour(ts - INTERVAL 1 MINUTE + INTERVAL 8 HOUR) * 3600
      + toMinute(ts - INTERVAL 1 MINUTE + INTERVAL 8 HOUR) * 60 BETWEEN 31500 AND 50399
GROUP BY symbol, trade_date
