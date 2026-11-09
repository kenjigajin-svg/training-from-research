#!/usr/bin/env python3
"""Build demo/demo.db: synthetic data in the real schema, so the queries run without
anyone's health data.

  python3 demo/make_demo_db.py

Nothing here comes from a real person. Sessions, heart rates and recovery are drawn from a
seeded random generator with a few effects built in (a hard session lowers next-morning HRV,
a short night lowers it further), so the queries have something to find. Load and the
fitness model use the same formulas as the real loader.
"""
import math
import random
import sqlite3
from datetime import date, datetime, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
DB = HERE / "demo.db"
WEEKS = 40
HR_REST, HR_MAX, TRIMP_K = 55, 190, 1.92
CTL_DAYS, ATL_DAYS = 42, 7

# sport, title, minutes, average HR range
SESSIONS = {
    "easy_run": ("running", "Easy run", 45, (132, 146)),
    "intervals": ("running", "Intervals", 50, (155, 168)),
    "long_ride": ("cycling", "Long ride", 120, (128, 142)),
    "zwift": ("cycling", "Zwift tempo", 60, (145, 158)),
    "gym": ("strength", "Gym", 60, (100, 118)),
    "muay_thai": ("muay_thai", "Muay Thai class", 75, (150, 165)),
    "swim": ("swimming", "Swim", 40, (125, 140)),
}
# weekday (0 = Monday) -> sessions most weeks
# Monday and Friday are rest days; an unplanned run sometimes lands on a Monday.
TEMPLATE = {0: [], 1: ["muay_thai"], 2: ["easy_run", "gym"], 3: ["intervals", "swim"],
            4: [], 5: ["long_ride"], 6: ["gym", "zwift"]}


def trimp(minutes, hr):
    x = (hr - HR_REST) / (HR_MAX - HR_REST)
    return minutes * x * 0.64 * math.exp(TRIMP_K * x)


def main():
    rng = random.Random(42)
    DB.unlink(missing_ok=True)
    db = sqlite3.connect(DB)
    db.executescript((HERE.parent / "schema.sql").read_text())
    for i, kind in enumerate(["garmin_api_json", "zwift_fit", "plan_json"], 1):
        db.execute("INSERT INTO source_file VALUES (?,?,?,?)",
                   (i, f"demo/{kind}", f"demo-{kind}", kind))
    for metric, value in [("hr_rest", HR_REST), ("hr_max", HR_MAX), ("trimp_k", TRIMP_K)]:
        db.execute("INSERT INTO threshold VALUES (?,?,?,?,?)",
                   (metric, value, "2000-01-01", "demo", None))

    today = date.today()
    start = today - timedelta(weeks=WEEKS, days=today.weekday())
    off = {start + timedelta(weeks=12, days=d) for d in range(14)}   # a two-week break
    block = {start + timedelta(weeks=30, days=d) for d in range(14)}  # a two-week overload
    plan_from = today - timedelta(weeks=6, days=today.weekday())

    day_load, day_kind, act_id = {}, {}, 0
    d = start
    while d < today:
        load = 0.0
        if d not in off:
            keys = [(k, d >= plan_from) for k in TEMPLATE[d.weekday()]]
            if d.weekday() == 0 and rng.random() < 0.35:
                keys.append(("easy_run", False))
            for key, planned in keys:
                sport, title, minutes, (lo, hi) = SESSIONS[key]
                hour = 18 if key in ("muay_thai", "gym") else 7
                when = datetime(d.year, d.month, d.day, hour, rng.choice([0, 15, 30]))
                if planned:
                    db.execute(
                        "INSERT INTO planned_session (start_local, date, weekday, week, title,"
                        " sport, minutes, plan_file, source_file_id) VALUES (?,?,?,?,?,?,?,?,3)",
                        (when.strftime("%Y-%m-%d %H:%M:%S"), d.isoformat(), when.strftime("%a"),
                         (d - timedelta(days=d.weekday())).isoformat(), title, sport, minutes,
                         "demo-plan.json"))
                if rng.random() < 0.12:
                    continue  # skipped: missed if planned, simply absent if not
                mins = minutes * rng.uniform(0.8, 1.2) * (1.4 if d in block else 1)
                hr = rng.uniform(lo, hi) + (4 if d in block else 0)
                act_id += 1
                db.execute(
                    "INSERT INTO activity_all (id, source, source_file_id, start_local, sport,"
                    " source_type, title, duration_s, avg_hr, hr_usable) VALUES"
                    " (?,?,?,?,?,?,?,?,?,1)",
                    (act_id, "zwift" if key == "zwift" else "garmin_api", 2 if key == "zwift" else 1,
                     when.strftime("%Y-%m-%d %H:%M:%S"), sport, sport.title(), title,
                     mins * 60, round(hr)))
                if key == "zwift":  # the watch recorded the same ride: kept, but superseded
                    db.execute(
                        "INSERT INTO activity_all (id, source, source_file_id, start_local, sport,"
                        " source_type, title, duration_s, avg_hr, hr_usable, superseded_by)"
                        " VALUES (?,?,?,?,?,?,?,?,?,1,?)",
                        (act_id + 100000, "garmin_api", 1, when.strftime("%Y-%m-%d %H:%M:%S"),
                         sport, "Virtual Ride", title, mins * 60, round(hr), act_id))
                t = trimp(mins, hr)
                db.execute("INSERT INTO activity_load (activity_id, load, load_method, load_hr,"
                           " hr_rest, hr_max) VALUES (?,?,?,?,?,?)",
                           (act_id, t, "hr_avg", t, HR_REST, HR_MAX))
                if planned:
                    db.execute("UPDATE planned_session SET activity_id = ? WHERE start_local = ?"
                               " AND title = ?", (act_id, when.strftime("%Y-%m-%d %H:%M:%S"), title))
                load += t
                day_kind.setdefault(d, set()).add(key)
        day_load[d] = load
        d += timedelta(days=1)

    # Next week's plan, not done yet.
    for i in range(7):
        d = today + timedelta(days=i)
        for key in TEMPLATE[d.weekday()]:
            sport, title, minutes, _ = SESSIONS[key]
            db.execute("INSERT OR IGNORE INTO planned_session (start_local, date, weekday, week, title,"
                       " sport, minutes, plan_file, source_file_id) VALUES (?,?,?,?,?,?,?,?,3)",
                       (f"{d.isoformat()} 19:00:00", d.isoformat(), d.strftime("%a"),
                        (d - timedelta(days=d.weekday())).isoformat(), title, sport, minutes,
                        "demo-plan.json"))

    # Fitness model and next-morning recovery.
    ctl = atl = 0.0
    d = start
    while d < today:
        load = day_load[d]
        db.execute("INSERT INTO fitness_day VALUES (?,?,?,?,?)",
                   (d.isoformat(), load, ctl, atl, ctl - atl))
        ctl += (load - ctl) / CTL_DAYS
        atl += (load - atl) / ATL_DAYS
        nxt = d + timedelta(days=1)
        hard = "muay_thai" in day_kind.get(d, set())
        sleep_h = rng.gauss(7.2, 0.7) - (0.4 if hard else 0)
        hrv = rng.gauss(41, 4) - (7 if hard else 0) - 0.03 * load + 1.2 * (sleep_h - 7.2)
        rhr = rng.gauss(58.6, 1.2) + 0.008 * load - 0.3 * (sleep_h - 7.2)
        db.execute("INSERT INTO daily (date, resting_hr, hrv_ms, sleep_s) VALUES (?,?,?,?)",
                   (nxt.isoformat(), round(rhr), round(hrv, 1), sleep_h * 3600))
        d = nxt

    # Placeholder evidence registry: a dozen claims, not the real one.
    for i in range(1, 9):
        db.execute("INSERT INTO evidence_source (id, title, year, status, evidence_level,"
                   " relevance, licence, visibility) VALUES (?,?,?,?,?,?,?,?)",
                   (f"S{i:03d}", f"Demo source {i}", 2015 + i, "included", 1 + i % 5,
                    "ABC"[i % 3], "CC-BY", "public"))
    for i, strength in enumerate(["High", "Moderate", "Moderate", "Low", "Low", "Low",
                                  "Very low", "Very low", "Very low", "Very low", "Low",
                                  "Moderate"], 1):
        db.execute("INSERT INTO evidence_claim (claim_id, claim, used_in, strength, visibility)"
                   " VALUES (?,?,?,?,?)",
                   (f"C{i:02d}", f"Demo claim {i}", f"plan rule {i}", strength, "public"))
        n = 0 if strength == "Very low" and i % 2 else 1 + i % 3  # some rules: expert practice
        for j in range(n):
            db.execute("INSERT OR IGNORE INTO evidence_claim_source VALUES (?,?)",
                       (f"C{i:02d}", f"S{1 + (i + j) % 8:03d}"))

    db.commit()
    n = db.execute("SELECT COUNT(*) FROM activity").fetchone()[0]
    print(f"{DB.name}: {n} activities over {WEEKS} weeks, synthetic")


if __name__ == "__main__":
    main()
