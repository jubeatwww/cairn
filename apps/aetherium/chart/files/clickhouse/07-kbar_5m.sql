-- From market-tap's docs/kbar-schema.sql (kbar_60m, with W = 5).
-- 盤中週期 kbar_{5,15,30,60}m:日盤(08:45~13:50)以 08:45 起錨,其餘(夜盤
-- 15:00 本身對齊日曆)日曆對齊;bar 標籤 = 區間結束。
-- 注意 if() 兩分支必須同型別(toUInt32),否則 CH 26 推成 Variant → DateTime 運算變 Nullable。
CREATE OR REPLACE VIEW kbar_5m AS
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
           toUInt32(31500 + intDiv(toInt64(sod) - 31500, 5 * 60) * 5 * 60),
           toUInt32(intDiv(sod, 5 * 60) * 5 * 60)) AS bucket_sod,
        toDateTime(toStartOfDay(ts - INTERVAL 1 MINUTE + INTERVAL 8 HOUR)) + bucket_sod + 5 * 60 - INTERVAL 8 HOUR AS bar_ts
    FROM kbar_1m_canonical
)
GROUP BY symbol, bar_ts
