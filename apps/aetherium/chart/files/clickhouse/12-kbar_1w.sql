-- From market-tap's docs/kbar-schema.sql.
-- 週 K:從日 K 聚合,週一起算。
CREATE OR REPLACE VIEW kbar_1w AS
SELECT
    toStartOfWeek(trade_date, 1) AS week_start, symbol,
    argMin(open, trade_date) AS open, max(high) AS high, min(low) AS low, argMax(close, trade_date) AS close,
    sum(volume) AS volume, sum(amount) AS amount
FROM kbar_1d
GROUP BY symbol, week_start
