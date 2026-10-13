-- From market-tap's docs/kbar-schema.sql (kbar_60m, with W = 30); see 07-kbar_5m.sql.
-- 已知邊角:13:45 收盤集合競價的 1 分 bar(標 13:46)在 30m/60m 會落入下一個
-- 起錨桶,若當日有 13:45:00 整點成交會出現一根孤立小 bar — 屬慣例選擇,先不併。
CREATE OR REPLACE VIEW kbar_30m AS
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
           toUInt32(31500 + intDiv(toInt64(sod) - 31500, 30 * 60) * 30 * 60),
           toUInt32(intDiv(sod, 30 * 60) * 30 * 60)) AS bucket_sod,
        toDateTime(toStartOfDay(ts - INTERVAL 1 MINUTE + INTERVAL 8 HOUR)) + bucket_sod + 30 * 60 - INTERVAL 8 HOUR AS bar_ts
    FROM kbar_1m_canonical
)
GROUP BY symbol, bar_ts
