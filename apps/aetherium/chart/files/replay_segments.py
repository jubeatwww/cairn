#!/usr/bin/env python3
"""計算期貨 tick/orderbook 的 session 覆蓋統計,upsert 到 amt.replay_segments。

從 ClickHouse 算每個 (symbol, session_date, session) 的筆數/起訖/最大間隙,
寫進 Postgres 供模擬盤 service 查詢可回放區間(見 migrations/20260808000001)。

Session 切分(台北時間),只統計實際交易時段、排除盤前快照與盤後尾巴
(收集器 08:25 起有 book 快照但 08:45 才開盤,直接納入會產生 20 分鐘假 gap):
  day   = 08:44:00 ~ 13:45:59(含開/收盤集合競價)
  night = 14:59:00 ~ 隔日 05:00:59(UTC 下為同日 06:59→21:00,不跨午夜)

usable 判定基於 orderbook(集合競價與冷清時段本來就沒 tick):
  邊界涵蓋(首筆 ≤ 名目開盤+TOL、末筆 ≥ 名目收盤-TOL)且 book 最大間隙 ≤ 門檻且有 tick。

自舉:amt.replay_segments 為空 → 全量回填(2026-06-17 起);否則重算最近 RECENT_DAYS 天。

環境變數:CH_URL、DATABASE_URL
"""

import datetime as dt
import os

import clickhouse_connect
import psycopg

SYMBOLS = ["FITXN*1.TF", "FIMTXN*1.TF", "FITMN*1.TF"]
BACKFILL_START = dt.date(2026, 6, 17)
RECENT_DAYS = 3
TOL_S = 120
MAX_BOOK_GAP = {"day": 180, "night": 300}

# 每個 session 的名目起訖(UTC time-of-day;夜盤在 UTC 同一天 07:00→21:00)
NOMINAL = {
    "day": (dt.time(0, 45), dt.time(5, 45)),
    "night": (dt.time(7, 0), dt.time(21, 0)),
}

STATS_SQL = """
SELECT symbol, session, session_date, count() AS rows,
       min(ts) AS min_ts, max(ts) AS max_ts, max(gap_s) AS max_gap_s
FROM (
    SELECT symbol, ts, session, session_date,
           toFloat64(ts - lagInFrame(ts, 1, ts) OVER (
               PARTITION BY symbol, session_date, session ORDER BY ts
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS gap_s
    FROM (
        SELECT symbol, ts,
               toHour(ts + INTERVAL 8 HOUR) * 3600 + toMinute(ts + INTERVAL 8 HOUR) * 60
                 + toSecond(ts + INTERVAL 8 HOUR) AS sod,
               if(sod >= 31440 AND sod < 49560, 'day', 'night') AS session,
               if(sod < 18060, toDate(ts + INTERVAL 8 HOUR) - 1, toDate(ts + INTERVAL 8 HOUR)) AS session_date
        FROM {table}
        WHERE symbol IN %(symbols)s AND ts >= %(since)s
          AND (sod BETWEEN 31440 AND 49559 OR sod >= 53940 OR sod < 18060)
    )
)
GROUP BY symbol, session, session_date
"""


def load_stats(ch, table, since):
    res = ch.query(STATS_SQL.format(table=table),
                   parameters={"symbols": tuple(SYMBOLS), "since": since})
    out = {}
    for sym, session, sdate, rows, min_ts, max_ts, max_gap in res.result_rows:
        out[(sym, sdate, session)] = (rows, min_ts, max_ts, round(max_gap))
    return out


def judge(session, sdate, book):
    if book is None:
        return False
    rows, first, last, gap = book
    nstart, nend = NOMINAL[session]
    # 夜盤在 UTC 下為同一天 07:00→21:00,名目起訖無須跨日位移
    nominal_start = dt.datetime.combine(sdate, nstart)
    nominal_end = dt.datetime.combine(sdate, nend)
    return (first <= nominal_start + dt.timedelta(seconds=TOL_S)
            and last >= nominal_end - dt.timedelta(seconds=TOL_S)
            and gap <= MAX_BOOK_GAP[session])


def main():
    ch = clickhouse_connect.get_client(dsn=os.environ.get("CH_URL", "http://localhost:8123"))
    pg = psycopg.connect(os.environ["DATABASE_URL"])

    with pg.cursor() as cur:
        cur.execute("SELECT count(*) FROM amt.replay_segments")
        empty = cur.fetchone()[0] == 0
    since = (dt.datetime.combine(BACKFILL_START, dt.time()) if empty
             else dt.datetime.utcnow() - dt.timedelta(days=RECENT_DAYS))
    print(f"[replay_segments] since={since} (bootstrap={empty})", flush=True)

    ticks = load_stats(ch, "tick_futures", since)
    books = load_stats(ch, "orderbook_futures", since)

    upserts = 0
    with pg.cursor() as cur:
        for key in sorted(set(ticks) | set(books)):
            sym, sdate, session = key
            t, b = ticks.get(key), books.get(key)
            first = min(x[1] for x in (t, b) if x)
            last = max(x[2] for x in (t, b) if x)
            usable = judge(session, sdate, b) and t is not None
            cur.execute("""
                INSERT INTO amt.replay_segments
                    (symbol, session_date, session, start_ts, end_ts,
                     tick_rows, book_rows, max_tick_gap_s, max_book_gap_s, usable, computed_at)
                VALUES (%s, %s, %s, %s AT TIME ZONE 'UTC', %s AT TIME ZONE 'UTC',
                        %s, %s, %s, %s, %s, NOW())
                ON CONFLICT (symbol, session_date, session) DO UPDATE SET
                    start_ts = EXCLUDED.start_ts, end_ts = EXCLUDED.end_ts,
                    tick_rows = EXCLUDED.tick_rows, book_rows = EXCLUDED.book_rows,
                    max_tick_gap_s = EXCLUDED.max_tick_gap_s,
                    max_book_gap_s = EXCLUDED.max_book_gap_s,
                    usable = EXCLUDED.usable, computed_at = NOW()
            """, (sym, sdate, session, first, last,
                  t[0] if t else 0, b[0] if b else 0,
                  t[3] if t else None, b[3] if b else None, usable))
            upserts += 1
    pg.commit()
    print(f"[replay_segments] upserted {upserts} sessions", flush=True)
    pg.close()


if __name__ == "__main__":
    main()
