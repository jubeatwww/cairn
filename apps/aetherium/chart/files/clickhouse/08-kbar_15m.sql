-- From market-tap's docs/kbar-schema.sql (kbar_60m, with W = 15); see 07-kbar_5m.sql.
CREATE OR REPLACE VIEW kbar_15m AS
SELECT
    bar_ts AS ts, symbol,
    argMin(open, src_ts) AS open, max(high) AS high, min(low) AS low, argMax(close, src_ts) AS close,
    sum(volume) AS volume, sum(amount) AS amount
FROM (
    SELECT
        ts AS src_ts, symbol, open, high, low, close, volume, amount,
        toHour(ts - INTERVAL 1 MINUTE + INTERVAL 8 HOUR) * 3600
          + toMinute(ts - INTERVAL 1 MINUTE + INTERVAL 8 HOUR) * 60 AS sod,
        if(sod >= 31500 AND sod < 50400,
           toUInt32(31500 + intDiv(toInt64(sod) - 31500, 15 * 60) * 15 * 60),
           toUInt32(intDiv(sod, 15 * 60) * 15 * 60)) AS bucket_sod,
        toDateTime(toStartOfDay(ts - INTERVAL 1 MINUTE + INTERVAL 8 HOUR)) + bucket_sod + 15 * 60 - INTERVAL 8 HOUR AS bar_ts
    FROM kbar_1m_canonical
)
GROUP BY symbol, bar_ts
