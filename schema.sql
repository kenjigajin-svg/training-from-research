-- One SQLite database for training, recovery, gym and food data from four apps.
-- Built from raw exports by a loader; disposable: rebuild, never edit by hand.
-- Times are local unless a column says utc.

-- Every raw file that was loaded. Byte-identical files load once.
CREATE TABLE source_file (
  id INTEGER PRIMARY KEY,
  path TEXT NOT NULL,
  sha256 TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL              -- zwift_fit | garmin_csv | garmin_api_json | fitatu_xls | hevy_json | apple_health_json | plan_json | ...
);

-- One row per recorded activity, every source. Duplicates are kept and pointed at the
-- row that wins (superseded_by), so the dedupe can be audited. Query the view, not this.
CREATE TABLE activity_all (
  id INTEGER PRIMARY KEY,
  source TEXT NOT NULL,           -- zwift | garmin_csv | garmin_api | manual
  source_file_id INTEGER NOT NULL REFERENCES source_file(id),
  start_local TEXT NOT NULL,      -- 'YYYY-MM-DD HH:MM:SS'
  start_utc TEXT,                 -- only where the source has it (FIT)
  sport TEXT NOT NULL,            -- running | cycling | swimming | strength | cardio | muay_thai | stairs | walking | mobility
  source_type TEXT NOT NULL,      -- the source's own label, e.g. 'Treadmill Running'
  title TEXT,
  duration_s REAL,
  moving_s REAL,
  distance_m REAL,
  calories REAL,
  avg_hr REAL,
  max_hr REAL,
  hr_usable INTEGER NOT NULL,     -- 0 when missing or implausible
  avg_power REAL,
  max_power REAL,
  norm_power REAL,
  avg_cadence REAL,
  ascent_m REAL,
  aerobic_te REAL,
  total_sets INTEGER,
  total_reps INTEGER,
  short INTEGER NOT NULL DEFAULT 0,  -- under 5 minutes: flagged, not training
  superseded_by INTEGER REFERENCES activity_all(id),
  filled_from INTEGER REFERENCES activity_all(id),  -- duplicate whose fields filled gaps here
  filled_fields TEXT,
  raw TEXT                        -- source row or session message as JSON
);

CREATE VIEW activity AS
  SELECT * FROM activity_all WHERE superseded_by IS NULL AND short = 0;

CREATE TABLE lap (
  activity_id INTEGER NOT NULL REFERENCES activity_all(id),
  lap_no INTEGER NOT NULL,
  start_utc TEXT,
  duration_s REAL,
  distance_m REAL,
  avg_hr REAL,
  max_hr REAL,
  avg_power REAL,
  avg_cadence REAL,
  PRIMARY KEY (activity_id, lap_no)
);

-- Second-by-second samples from FIT files.
CREATE TABLE stream (
  activity_id INTEGER NOT NULL REFERENCES activity_all(id),
  t_s INTEGER NOT NULL,           -- seconds from activity start
  hr REAL, power REAL, cadence REAL, speed REAL,
  PRIMARY KEY (activity_id, t_s)
) WITHOUT ROWID;

-- Dated thresholds. The value valid on a date is the latest row on or before it; before
-- the first row, the first row applies.
CREATE TABLE threshold (
  metric TEXT NOT NULL,           -- hr_rest | hr_max | ftp | trimp_k
  value REAL NOT NULL,
  valid_from TEXT NOT NULL,
  source TEXT NOT NULL,
  note TEXT,
  PRIMARY KEY (metric, valid_from)
);

-- Load per kept activity. load is Banister TRIMP; load_power is TSS.
CREATE TABLE activity_load (
  activity_id INTEGER PRIMARY KEY REFERENCES activity_all(id),
  load REAL,                      -- the value the charts use, NULL when nothing usable
  load_method TEXT NOT NULL CHECK (load_method IN
    ('hr_stream','hr_avg','hr_avg_watch','power_scaled','none')),
  load_hr REAL,                   -- TRIMP, when HR is usable
  load_power REAL,                -- TSS, when power and FTP exist
  norm_power REAL,
  hr_rest REAL, hr_max REAL, ftp REAL  -- thresholds used, for audit
);

-- Daily fitness model: CTL 42-day, ATL 7-day exponentially weighted daily load.
-- TSB uses yesterday's CTL and ATL.
CREATE TABLE fitness_day (
  date TEXT PRIMARY KEY,
  load REAL NOT NULL,
  ctl REAL NOT NULL, atl REAL NOT NULL, tsb REAL NOT NULL
);

-- The same model per sport group: cycling, running, strength, swimming, other.
CREATE TABLE fitness_sport_day (
  date TEXT NOT NULL,
  sport_group TEXT NOT NULL,
  load REAL NOT NULL,
  ctl REAL NOT NULL, atl REAL NOT NULL, tsb REAL NOT NULL,
  PRIMARY KEY (date, sport_group)
);

-- Wellness, one row per day. Each field has exactly one source, named in daily_source;
-- nothing is merged across sources. NULL means not measured that day.
CREATE TABLE daily (
  date TEXT PRIMARY KEY,
  resting_hr REAL,
  hrv_ms REAL,                      -- overnight HRV, rMSSD
  hrv_base_low REAL,                -- the watch's own baseline band for that day
  hrv_base_high REAL,
  sleep_s REAL,                     -- deep + light + REM, awake time excluded
  deep_s REAL,
  rem_s REAL,
  sleep_score INTEGER,
  sleep_start TEXT,
  sleep_end TEXT,
  stress_avg REAL,
  body_battery_high REAL,
  body_battery_low REAL,
  steps INTEGER,
  vo2max_run REAL
);

CREATE TABLE daily_source (
  field TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  note TEXT
);

-- Gym log. One row per workout, linked to the watch's Strength activity when their times
-- overlap. The watch knows a gym session happened; only the gym app knows what was in it.
CREATE TABLE gym_session (
  id INTEGER PRIMARY KEY,
  hevy_id TEXT NOT NULL UNIQUE,
  source_file_id INTEGER NOT NULL REFERENCES source_file(id),
  start_local TEXT NOT NULL,
  end_local TEXT,
  start_utc TEXT NOT NULL,
  title TEXT,
  routine_id TEXT,
  activity_id INTEGER REFERENCES activity_all(id),
  raw TEXT
);

CREATE TABLE gym_set (
  session_id INTEGER NOT NULL REFERENCES gym_session(id),
  exercise_index INTEGER NOT NULL,
  set_index INTEGER NOT NULL,
  exercise TEXT NOT NULL,         -- the app's exercise title
  template_id TEXT,               -- the app's exercise id, stable across renames
  set_type TEXT,                  -- normal | warmup | dropset | failure
  weight_kg REAL,                 -- NULL for body weight
  reps INTEGER,
  rpe REAL,
  duration_s REAL,
  distance_m REAL,
  superset_id INTEGER,
  notes TEXT,
  PRIMARY KEY (session_id, exercise_index, set_index)
);

-- Food diary export. Item rows only; day and meal totals are rebuilt in SQL. NULL means the
-- product carries no value for that nutrient, not zero.
CREATE TABLE meal_map (
  source_meal TEXT PRIMARY KEY,   -- the app's label
  meal TEXT NOT NULL CHECK (meal IN ('breakfast','lunch','dinner','snack','other'))
);

-- The four main nutrient columns are listed here; the loader adds the rest from the export
-- header (39 in all, snake_case with the unit kept: vitamin_d_ug, sodium_mg, ...).
CREATE TABLE nutrition_item (
  date TEXT NOT NULL,
  source_meal TEXT NOT NULL REFERENCES meal_map(source_meal),
  position INTEGER NOT NULL,      -- order within the meal, from 1
  food TEXT NOT NULL,
  kitchen_measure TEXT,
  quantity_g REAL,
  calories_kcal REAL,
  protein_g REAL,
  fats_g REAL,
  carbohydrates_g REAL,
  source_file_id INTEGER NOT NULL REFERENCES source_file(id),
  PRIMARY KEY (date, source_meal, position)
);

-- Complete diary days: at least 1,200 kcal across at least 3 meals.
CREATE VIEW nutrition_day AS
  SELECT i.date, COUNT(*) items, COUNT(DISTINCT m.meal) meals,
         SUM(calories_kcal) kcal, SUM(protein_g) protein_g,
         SUM(carbohydrates_g) carbs_g, SUM(fats_g) fat_g,
         (SUM(calories_kcal) >= 1200 AND COUNT(DISTINCT m.meal) >= 3) AS complete
    FROM nutrition_item i JOIN meal_map m USING (source_meal)
   GROUP BY i.date;

-- The app's own totals, kept only to check the rebuilt ones.
CREATE TABLE fitatu_total (
  date TEXT NOT NULL,
  source_meal TEXT NOT NULL,      -- '' for the day row
  quantity_g REAL,
  calories_kcal REAL,
  protein_g REAL,
  fats_g REAL,
  carbohydrates_g REAL,
  PRIMARY KEY (date, source_meal)
);

-- Daily nutrition via the phone's health store: fills days the monthly export has not
-- reached yet. One row per day and metric.
CREATE TABLE health_metric (
  date TEXT NOT NULL,
  metric TEXT NOT NULL,           -- kcal | protein_g | carbs_g | fat_g | fiber_g | sugar_g | weight_kg | body_fat_pct
  value REAL NOT NULL,
  source TEXT,
  source_file_id INTEGER NOT NULL REFERENCES source_file(id),
  PRIMARY KEY (date, metric)
);

CREATE VIEW health_nutrition_day AS
  SELECT date,
         MAX(CASE WHEN metric='kcal' THEN value END) kcal,
         MAX(CASE WHEN metric='protein_g' THEN value END) protein_g,
         MAX(CASE WHEN metric='carbs_g' THEN value END) carbs_g,
         MAX(CASE WHEN metric='fat_g' THEN value END) fat_g
    FROM health_metric WHERE metric IN ('kcal','protein_g','carbs_g','fat_g')
   GROUP BY date;

-- Diet targets per day type. A day's type is the highest points_from at or below that
-- day's training load. Dated like thresholds.
CREATE TABLE diet_target (
  valid_from TEXT NOT NULL,
  day_type TEXT NOT NULL,
  points_from REAL NOT NULL,
  kcal REAL, protein_g REAL, carbs_g REAL, fat_g REAL,
  in_session_carbs TEXT,
  kcal_per_hour_over_3h REAL,
  note TEXT,
  PRIMARY KEY (valid_from, day_type)
);

-- Every day with its type, targets and actual intake. Diary export wins over the health
-- store where both exist.
CREATE TABLE day_target (
  date TEXT PRIMARY KEY,
  load REAL NOT NULL,
  day_type TEXT NOT NULL,
  target_version TEXT NOT NULL,
  kcal_target REAL, protein_target REAL, carbs_target REAL, fat_target REAL,
  logged INTEGER NOT NULL,
  complete INTEGER NOT NULL,        -- at least 1,200 kcal across at least 3 meals
  kcal REAL, protein_g REAL, carbs_g REAL, fat_g REAL,
  food_source TEXT                  -- fitatu_xls | apple_health, NULL when nothing logged
);

-- Planned sessions, one row per session whatever plan file it sits in (the files overlap
-- and do not run Monday to Sunday). Each is matched to the activity of the same sport on
-- the same day that starts nearest to it; each activity matches once.
CREATE TABLE planned_session (
  id INTEGER PRIMARY KEY,
  start_local TEXT NOT NULL,
  end_local TEXT,
  date TEXT NOT NULL,
  weekday TEXT NOT NULL,          -- Mon..Sun, from the date
  week TEXT NOT NULL,             -- Monday of the week
  title TEXT NOT NULL,
  sport TEXT,                     -- inferred from the title; NULL when no keyword matches
  minutes REAL,
  target_hr REAL,
  cancelled INTEGER NOT NULL DEFAULT 0,
  event_id TEXT,
  description TEXT,
  plan_file TEXT NOT NULL,
  source_file_id INTEGER NOT NULL REFERENCES source_file(id),
  activity_id INTEGER REFERENCES activity_all(id),
  UNIQUE (start_local, title)
);

-- Planned against done. status: done | missed | upcoming | cancelled.
CREATE VIEW plan_vs_actual AS
  SELECT p.week, p.date, p.weekday, substr(p.start_local, 12, 5) AS planned_time, p.title,
         p.sport, p.minutes AS planned_min, p.target_hr,
         CASE WHEN p.cancelled THEN 'cancelled'
              WHEN p.activity_id IS NOT NULL THEN 'done'
              WHEN p.date >= date('now', 'localtime') THEN 'upcoming'
              ELSE 'missed' END AS status,
         substr(a.start_local, 12, 5) AS actual_time, ROUND(a.duration_s / 60.0) AS actual_min,
         ROUND(a.avg_hr) AS avg_hr, ROUND(l.load) AS load, p.activity_id, p.plan_file
    FROM planned_session p
    LEFT JOIN activity a ON a.id = p.activity_id
    LEFT JOIN activity_load l ON l.activity_id = p.activity_id;

-- Evidence registry: every scientific source the plan rests on, how it got in, and what it
-- is used for. Kept as CSV under version control and loaded here on every build.
CREATE TABLE evidence_source (
  id TEXT PRIMARY KEY, doi TEXT, title TEXT, authors TEXT, year INTEGER, journal TEXT,
  study_type TEXT,
  licence TEXT,                   -- CC-BY | CC-BY-NC | CC-BY-NC-ND | closed | ...
  open_access TEXT, url TEXT,
  tier TEXT,                      -- 1 = peer-reviewed; lower-trust sources are kept elsewhere
  visibility TEXT,                -- public | private
  status TEXT,                    -- candidate | included | excluded | retired
  evidence_level INTEGER,         -- 1 meta-analysis of RCTs .. 5 expert opinion or mechanism
  relevance TEXT,                 -- A trained endurance or combat athletes .. C untrained, clinical, animal
  grade_basis TEXT, topics TEXT
);

-- One finding a plan rule rests on. strength is computed from the best supporting source,
-- never typed: High needs level 1 in trained adults; expert-practice rules cap at Low.
CREATE TABLE evidence_claim (
  claim_id TEXT PRIMARY KEY, topic TEXT, claim TEXT,
  rule_ref TEXT,                  -- where the review states it
  used_in TEXT,                   -- the plan rule that uses it; empty when unused
  evidence_note TEXT,
  strength TEXT,                  -- High | Moderate | Low | Very low
  strength_basis TEXT,            -- which source decided it
  visibility TEXT
);

CREATE TABLE evidence_claim_source (
  claim_id TEXT REFERENCES evidence_claim(claim_id),
  source_id TEXT REFERENCES evidence_source(id),
  PRIMARY KEY (claim_id, source_id)
);

-- Append-only: every status or grade change, with the reason and who made it.
CREATE TABLE evidence_log (
  date TEXT, source_id TEXT, field TEXT, old TEXT, new TEXT, reason TEXT, by TEXT
);
