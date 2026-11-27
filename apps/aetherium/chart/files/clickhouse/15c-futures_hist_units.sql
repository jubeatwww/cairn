-- futures_hist_units: the futures' sessions Shioaji's history has, per (product, contract,
-- session), which tick_futures prefers to the stream. tick_futures used to work them out from
-- market_trades in every query: a scan of all the futures' history whatever the time range (23
-- million rows, 5 s on 2026-11-28, for under 200 sessions), too slow for hindsight, whose replay
-- reads a few seconds at a time. A refreshable materialized view works them out again every 5
-- minutes instead: for up to that long after a session's history is written or deleted,
-- tick_futures shows both its stream and its history, or neither.
-- A session's key as in tick_futures: the date it opens on in Taiwan time less 6 hours, and the
-- session column (day / night).
CREATE MATERIALIZED VIEW IF NOT EXISTS futures_hist_units
REFRESH EVERY 5 MINUTE
ENGINE = MergeTree
ORDER BY (symbol, contract, day, session)
AS SELECT DISTINCT symbol, contract, toDate(ts + INTERVAL 2 HOUR) AS day, session
FROM market_trades
WHERE asset = 'futures' AND source = 'sinopac' AND origin = 'hist'
