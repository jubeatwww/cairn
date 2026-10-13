-- From market-tap's docs/kbar-schema.sql.
-- Canonical 層:每個(商品, 台北日)恰好路由到一個 source。
-- 規則(2026-08-08 接縫對比定案):
--   1. 2026-06-22 前(自家 tick_futures 尚未收)→ shioaji_hist
--   2. 12 個日盤缺失日(futures_day WS lease 修復 f80bd1a 之前的故障日)→ shioaji_hist
--   3. 其餘 → tick_agg
-- 已知差異:健康日 MoneyDJ 日總量比 Shioaji 高 ~0.5%(疑價差腳位計量語意),
-- 待以期交所官方日成交量裁決;OHLC 精確吻合率 98.7~99.4%。
CREATE OR REPLACE VIEW kbar_1m_canonical AS
SELECT
    ts,
    transform(symbol, ['TXFR1','MXFR1','TMFR1'], ['TXF','MXF','TMF'], symbol) AS symbol,
    open, high, low, close, volume, amount, source
FROM kbar_1m FINAL
WHERE source = if(
    toDate(ts + INTERVAL 8 HOUR) < toDate('2026-06-22')
    OR toDate(ts + INTERVAL 8 HOUR) IN (
        toDate('2026-06-22'), toDate('2026-06-23'), toDate('2026-06-24'),
        toDate('2026-06-25'), toDate('2026-06-26'), toDate('2026-06-29'),
        toDate('2026-07-02'), toDate('2026-07-09'), toDate('2026-07-13'),
        toDate('2026-07-14'), toDate('2026-07-16'), toDate('2026-07-17')),
    'shioaji_hist', 'tick_agg')
