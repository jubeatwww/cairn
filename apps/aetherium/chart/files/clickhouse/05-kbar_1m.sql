-- From market-tap's docs/kbar-schema.sql.
-- kbar_1m:1 分 K 統一表(多來源共存,source 欄位記血統)。
-- 慣例:ts 為 UTC、bar 標籤 = 分鐘「結束」時刻(08:45 開盤第一根標 08:46,對齊 Shioaji)。
-- 來源:
--   shioaji_hist — Shioaji 歷史回補(scripts/backfill_kbars_sj.py,2020-03-02 起,2026-08-08 完成)
--   tick_agg     — 自家 tick_futures 聚合(CronJob kbar-tick-agg 每日 06:40 增量)
-- 消費者一律查 kbar_1m_canonical,不要直接讀 kbar_1m。
CREATE TABLE IF NOT EXISTS kbar_1m
(
    ts     DateTime                 CODEC(Delta(4), ZSTD(3)),
    symbol LowCardinality(String)   CODEC(ZSTD(3)),   -- R1 式連續近月碼:TXFR1 / MXFR1 / TMFR1(不分來源)
    source LowCardinality(String)   CODEC(ZSTD(3)),
    open   Float64                  CODEC(ZSTD(3)),
    high   Float64                  CODEC(ZSTD(3)),
    low    Float64                  CODEC(ZSTD(3)),
    close  Float64                  CODEC(ZSTD(3)),
    volume UInt32                   CODEC(ZSTD(3)),
    amount Float64                  CODEC(ZSTD(3))    -- Σ(價×口),指數點計價(未乘契約乘數),同 Shioaji 語意
)
ENGINE = ReplacingMergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (symbol, source, ts)
