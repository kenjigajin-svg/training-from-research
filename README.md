# Training from the research, measured in SQL

A closed loop: published research sets the rules of my training plan, the plan is pushed
automatically to the apps I train with, what actually happened is pulled back into one
database every morning and every ten minutes after that,
and SQL shows whether the plan held and how my body responded. The next plan is written
against both.

The data side had a problem first. It lived in four apps that do not talk to each other: a
Garmin watch for every session, Zwift for indoor rides, Hevy for what happened in the gym,
and Fitatu for food. None can answer "does my HRV drop after a hard session, and is the
sleep or the session to blame?", because the session is in one app and the morning after is
in another. So all four go into one SQLite database I designed, alongside the research
behind the plan.

This repo holds the schema, five of the queries, and a generator for synthetic data so the
queries run without anyone's health data.

**Part 1 of a three-part project.** Part 2 is a sports-science assistant built on the
open-access papers in the same evidence registry, with an evaluation harness. Part 3
compares it with a fine-tuned small model.

## The loop

```
  RESEARCH                     EVIDENCE REGISTRY                 PLAN
  5 topic reviews       ──>    237 sources, graded        ──>    season and gym plans,
  (strength, weekly            120 claims, strength              104 rules, each pointing
  structure, season,           computed, never typed             at the claim behind it
  technique, fuelling)                │                                 │
                                      │                                 v
                                      │                          PUSH
                                      │                          sessions to calendar,
                                      │                          Hevy, Zwift, the watch
                                      v                                 │
  QUERIES, DASHBOARD    <──    training.db              <──      TRAIN, then PULL daily
  did the plan hold,           19 + 4 evidence tables,           Garmin, Zwift, Hevy,
  how did I respond            dedupe, load model                Fitatu
          │
          └────────────>  next plan adjusts to what happened, and to the evidence
```

### Research to rules

Each of five topics, strength programming, weekly structure, season planning, technique,
and fuelling, has a written review of around 200 lines that grades every finding by the
quality of evidence behind it: several consistent meta-analyses, one or two, single trials,
or expert practice. The plan rules come from those reviews: rep ranges and effort for the
main lifts, how far heavy leg work sits from a long run or a combat session, how fast the
long run may grow, what to eat on a hard day.

### The evidence registry

Every source the reviews cite is one row in a registry, kept as plain CSV so every change
shows in git:

- **Screened and graded.** Each source gets an evidence level from 1 (meta-analysis of
  randomised trials) to 5 (expert opinion or mechanism), and a relevance from A (trained
  adults in endurance or combat sports) to C (untrained, clinical or animal). A level 1
  review in untrained people is weaker evidence for me than a level 2 trial in trained
  athletes, and the grade says so.
- **Logged, never silent.** Every status or grade change is appended to a screening log with
  a reason and who made it. Excluded and retired sources stay, so it is always visible what
  was dropped and why.
- **Claims carry the strength, computed.** A claim is one finding a plan rule rests on. Its
  strength, High to Very low, is computed from its best supporting source and never typed in.
  If the review itself calls a rule expert practice, the claim is capped at Low.
- **Licence tracked.** Only CC-BY papers can go into the public corpus Part 2 is built on;
  the rest can inform the plan but are cited, not copied. A private tier of lower-trust
  sources never leaves the machine.

The registry is loaded into the same database, so a query can ask how much of the plan
stands on strong evidence (query 5), and later how the body responded to the rules that
rest on weak evidence.

### How the apps connect

Nothing is copied by hand day to day. Every app is both a source and a destination, and two
scheduled jobs keep them in step:

| App | Data comes in | Plan goes out |
|---|---|---|
| Garmin watch | Activities, sleep, HRV, resting HR, through a community API client | Each planned run as a structured workout on its date; the watch shows it as today's workout |
| Zwift | Each ride's original FIT file, which Garmin returns byte for byte | Planned rides as structured workouts, powers in watts |
| Hevy | Every workout, set by set, through its API | Gym sessions as routines, exercises, sets and weights filled in |
| Fitatu | Daily food totals via the phone's health store, exported to a cloud folder; item-level detail from the monthly export | Each day's food target, set by that day's planned load |
| Google Calendar | Sessions moved or deleted there, treated as deliberate: the new time goes back into the plan file and is logged | Every session, plus an all-day event with the food target and meal split |

- **A daily job** runs at 06:30, on wake, and whenever Zwift saves a ride: it pulls every
  source, syncs calendar changes back into the plan, rebuilds the database and the phone
  pages, and commits the new raw files to git.
- **A quick job every ten minutes** pulls Hevy, the food totals and calendar changes, and
  pushes moved runs to the watch. A gym session or a meal shows on the phone within about
  twenty minutes; a run dragged to another day in the calendar is on the watch within ten.
- **Each step fails on its own.** One broken source does not stop the rest. If the morning
  job dies mid-download because the laptop went back to sleep, the quick job retries it
  hourly until it succeeds, and the dashboard warns when any source is more than 36 hours
  stale.
- **Moves become preferences slowly.** One moved session is an observation about that week.
  Only the same kind of move in three different weeks, decided on two different days,
  becomes a scheduling rule for future plans.

## The database

The schema is [`schema.sql`](schema.sql), in eight groups:

| Group | Tables | Why it exists |
|---|---|---|
| Provenance | `source_file` | Every row traces back to a raw file and its hash. A byte-identical file loads once |
| Activities | `activity_all`, `activity` (view), `lap`, `stream` | Every session from every source, duplicates included and pointed at the winner |
| Load and fitness | `threshold`, `activity_load`, `fitness_day`, `fitness_sport_day` | Heart-rate load per session, then a fitness and fatigue model per day |
| Recovery | `daily`, `daily_source` | Resting HR, HRV, sleep and Body Battery, one row per day |
| Gym | `gym_session`, `gym_set` | What the watch cannot see: exercise, set, weight, reps, RPE |
| Food | `nutrition_item`, `meal_map`, `fitatu_total`, `health_metric`, `diet_target`, `day_target` | Food item by item, rebuilt into day totals, checked against the app's own totals, compared with a target set by that day's training |
| Plans | `planned_session`, `plan_vs_actual` (view) | What was planned against what was done |
| Evidence | `evidence_source`, `evidence_claim`, `evidence_claim_source`, `evidence_log` | The research behind the plan: sources, grades, claims, and every change made to them |

## Design decisions

- **The database is disposable.** Nothing is edited in it by hand. To change a result, change
  a raw file or a rule file and rebuild. The build writes to a temporary file and swaps it in
  at the end, so the dashboard never reads a half-built database.
- **Duplicates are kept, not deleted.** A Zwift ride also arrives through the watch. Both rows
  stay in `activity_all`; the watch copy points at the Zwift one through `superseded_by`, and
  can lend it heart rate if the Zwift file has none (`filled_from`, `filled_fields`). The
  `activity` view hides the losers. The dedupe can always be audited.
- **One source per field.** Two apps report sleep differently. Instead of averaging them,
  each column of `daily` has exactly one source, recorded in `daily_source`. Merged numbers
  hide which app was wrong.
- **Thresholds are dated.** Resting and maximum heart rate change as fitness changes. Every
  load is computed with the thresholds valid on its own date, and the values used are stored
  on the row for audit.
- **Totals are rebuilt, then checked.** Food day totals are summed from item rows in SQL and
  compared against the app's exported totals, which catches a broken export before it
  reaches a chart.
- **Numbers in code, words in the answers.** The load model (Banister TRIMP, then 42-day and
  7-day exponentially weighted averages) is computed in Python and stored. Queries read it.

## Five questions, five techniques

Run against my own data, then written up in words rather than figures: the real data stays
private. The SQL is unchanged.

### 1. Weekly load by sport, and where were the gaps?
[`queries/01-weekly-load.sql`](queries/01-weekly-load.sql) · **conditional aggregation to pivot sports into columns, date bucketing**

Load built steadily from spring and peaked in a cycling-heavy block at the end of September.
The gaps are as visible as the peaks: a winter break with nothing logged, then a stretch of
gym only, which heart-rate load barely registers. That last point is a limitation of the
load model, not of the training, and it is why the gym tables exist.

### 2. HRV and resting HR the morning after a hard session
[`queries/02-recovery-after-session.sql`](queries/02-recovery-after-session.sql) · **correlated `EXISTS` subqueries to classify days, a self-join to the next day**

HRV is clearly lower the morning after a Muay Thai class than after a rest day; an easy run
sits in between. Resting HR barely moves. The obvious explanation was the late class cutting
sleep short, but sleep on those nights is close to normal, so the session itself is the
likelier cause. Few nights yet: a direction, not a conclusion.

### 3. Which weeks were monotonous or high strain?
[`queries/03-monotony-strain.sql`](queries/03-monotony-strain.sql) · **CTEs, standard deviation from `AVG(x²) − AVG(x)²`, `NULLIF` against division by zero**

Foster's monotony is mean daily load over its standard deviation for the week; strain is
weekly load times monotony. The biggest week had high load but low monotony, because the
hard and easy days were far apart. Two later weeks came close to Foster's 2.0 warning line
at much lower load, because every day looked the same. Strain can come from sameness, not
only from volume, so the fix is more contrast between hard and easy days rather than less
training.

### 4. Planned against done, per week
[`queries/04-plan-vs-actual.sql`](queries/04-plan-vs-actual.sql) · **`LEFT JOIN` to keep missed sessions, an anti-join for unplanned ones, `GROUP_CONCAT`**

Plans come from overlapping files that do not run Monday to Sunday, so the loader flattens
them into one row per session and matches each to the nearest activity of the same sport on
the same day. Four weeks in a row came out complete, then one week was mostly missed, and
the query names which sessions.

### 5. How much of the plan rests on strong evidence?
[`queries/05-evidence-behind-the-plan.sql`](queries/05-evidence-behind-the-plan.sql) · **`LEFT JOIN` with `COUNT` to keep claims that have no source, a scalar subquery for the share, `CASE` ordering**

These figures are about the plan, not about me, so they are given as they are. Of 104 claims
the plan rules use, 6 are High and 29 Moderate: about a third of the plan stands on solid
ground. 31 are Low and 38 Very low, and 22 of those rest on no published source at all.
That is coaching practice, not error, but it is the part to watch: those are the rules
where my own data, logged against them, is the best evidence I will get.

## A bug the write-up caught

Queries 1 and 3 first bucketed weeks with `date(x, 'weekday 1', '-7 days')`. That looks like
"the Monday of this week" and is not: SQLite's `weekday 1` leaves a Monday where it is, so
subtracting seven days moves every Monday into the week before. Weeks ran Tuesday to Monday
for a month without my noticing, because the totals looked plausible. Rerunning the
queries for this write-up showed a monotony figure that did not match the daily loads.
The fix is `date(x, '-6 days', 'weekday 1')`. It moved the weekly figures by one day's load and
changed which weeks ranked highest for strain.

## Run it

Python 3.9 or later, standard library only.

```bash
python3 demo/make_demo_db.py   # builds demo/demo.db: 40 weeks of synthetic data
python3 run.py                 # all five queries
python3 run.py 03              # one query
```

The demo data is generated, not sampled from anyone. It has a few effects built in, a hard
session lowers next-morning HRV, a short night lowers it further, so the queries have
something to find. Its numbers mean nothing beyond that. The demo evidence registry is a
dozen placeholder claims, not the real one.

## Limits

- Heart-rate load undercounts strength work, so every load figure understates gym weeks.
- The evidence grades were drafted with an AI model from the reviews and the abstracts, each
  with its reason logged, and are re-graded as sources are read in full. A grade is a
  starting point, not a verdict.
- Small samples on the questions that matter most: a handful of nights after each kind of
  session.
- Two of the four sources are pulled through unofficial routes, a community Garmin client
  and the phone's health store, and can break without warning. The daily pull reports when a
  source goes stale.

Built with an AI model in the loop, research included: I set the questions, the plan rules
and the data model, and read every query, answer and review before it went in.

## License

Code under the MIT License, see [`LICENSE`](LICENSE). No personal data is included; the demo data is synthetic.
