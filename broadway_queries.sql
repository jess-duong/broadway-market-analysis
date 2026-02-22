-- ============================================================
-- BROADWAY MARKET INTELLIGENCE: SQL QUERIES
-- Analyst: Jess Duong | Strategic Analyst, The Broadway League
-- Database: PostgreSQL
-- Dataset: 145 shows, 47,500+ weekly records (1995-2020)
-- ============================================================
-- Tables:
--   shows (show PK, show_type, show_category, opening_date, closing_date, source_notes)
--   financials (week_ending, show, weekly_gross, pct_capacity [0-1 scale], avg_ticket_price, ...)
--   tony_awards (show FK, year, category, result, num_nominations, num_wins)
-- ============================================================


-- ============================================================
-- QUERY SET 1: INDUSTRY OVERVIEW
-- Skills: COUNT, GROUP BY, window functions (SUM OVER), ROUND
-- ============================================================

-- Show count by category (what types of shows dominate Broadway?)
SELECT 
    show_category,
    COUNT(*) AS num_shows,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 1) AS pct_of_total
FROM shows
GROUP BY show_category
ORDER BY num_shows DESC;


-- Average total gross by category (which show types earn the most?)
SELECT 
    s.show_category,
    COUNT(*) AS num_shows,
    ROUND(AVG(f.total_gross)::numeric / 1000000, 2) AS avg_gross_millions,
    ROUND(MAX(f.total_gross)::numeric / 1000000, 2) AS max_gross_millions
FROM shows s
JOIN (
    SELECT show, SUM(weekly_gross) AS total_gross
    FROM financials
    GROUP BY show
) f ON s.show = f.show
GROUP BY s.show_category
ORDER BY avg_gross_millions DESC;


-- Average capacity % and ticket price by category (which types fill seats best?)
SELECT 
    s.show_category,
    COUNT(*) AS num_shows,
    ROUND(AVG(f.pct_capacity * 100)::numeric, 1) AS avg_capacity_pct,
    ROUND(AVG(f.avg_ticket_price)::numeric, 2) AS avg_ticket_price
FROM shows s
JOIN financials f ON s.show = f.show
WHERE f.week_ending >= '1995-01-01'
GROUP BY s.show_category
ORDER BY avg_capacity_pct DESC;


-- ============================================================
-- QUERY SET 2: MARKET TRENDS
-- Skills: JOINs, aggregations, date functions, EXTRACT
-- ============================================================

-- Industry trends by year (ticket prices, capacity, revenue growth)
-- Note: Cut off at March 2020 to avoid COVID shutdown skewing numbers
SELECT 
    EXTRACT(YEAR FROM f.week_ending)::INT AS year,
    ROUND(AVG(f.avg_ticket_price)::numeric, 2) AS avg_ticket_price,
    ROUND(AVG(f.pct_capacity * 100)::numeric, 1) AS avg_capacity_pct,
    ROUND(SUM(f.weekly_gross)::numeric / 1000000, 2) AS total_gross_millions,
    COUNT(DISTINCT f.show) AS num_active_shows
FROM financials f
WHERE f.week_ending >= '1995-01-01' AND f.week_ending < '2020-03-15'
GROUP BY EXTRACT(YEAR FROM f.week_ending)
ORDER BY year;


-- Year-over-year industry revenue growth using LAG
-- Skills: CTEs, LAG window function, NULLIF
WITH yearly_totals AS (
    SELECT 
        EXTRACT(YEAR FROM week_ending)::INT AS year,
        ROUND(SUM(weekly_gross)::numeric / 1000000, 2) AS total_gross_millions
    FROM financials
    WHERE week_ending >= '1995-01-01' AND week_ending < '2020-03-15'
    GROUP BY EXTRACT(YEAR FROM week_ending)
)
SELECT 
    year,
    total_gross_millions,
    LAG(total_gross_millions) OVER (ORDER BY year) AS prev_year_gross,
    ROUND(
        (total_gross_millions - LAG(total_gross_millions) OVER (ORDER BY year)) * 100.0 /
        LAG(total_gross_millions) OVER (ORDER BY year), 1
    ) AS yoy_pct_change
FROM yearly_totals
ORDER BY year;


-- ============================================================
-- QUERY SET 3: TONY AWARDS ANALYSIS
-- Skills: CTEs, CASE statements, date arithmetic, NULLIF, before/after analysis
-- ============================================================

-- Tony Awards ROI - Before/After revenue comparison
-- Compares avg weekly gross 26 weeks before vs. 26 weeks after Tony ceremony
-- Skills: CTEs, CASE, MAKE_DATE, INTERVAL, NULLIF, HAVING
WITH tony_dates AS (
    SELECT 
        t.show,
        t.year,
        MAKE_DATE(t.year, 6, 15) AS tony_ceremony_date
    FROM tony_awards t
    WHERE t.result = 'Won' AND t.category = 'Best Musical'
)
SELECT 
    td.show,
    td.year AS tony_year,
    ROUND(AVG(CASE 
        WHEN f.week_ending < td.tony_ceremony_date THEN f.weekly_gross 
    END)::numeric, 0) AS avg_weekly_before,
    ROUND(AVG(CASE 
        WHEN f.week_ending >= td.tony_ceremony_date 
             AND f.week_ending < td.tony_ceremony_date + INTERVAL '26 weeks'
        THEN f.weekly_gross 
    END)::numeric, 0) AS avg_weekly_after,
    ROUND(
        (AVG(CASE WHEN f.week_ending >= td.tony_ceremony_date 
                       AND f.week_ending < td.tony_ceremony_date + INTERVAL '26 weeks' 
                  THEN f.weekly_gross END) -
         AVG(CASE WHEN f.week_ending < td.tony_ceremony_date 
                  THEN f.weekly_gross END)) * 100.0 /
        NULLIF(AVG(CASE WHEN f.week_ending < td.tony_ceremony_date 
                        THEN f.weekly_gross END), 0),
        1
    )::numeric AS pct_change
FROM tony_dates td
JOIN financials f ON td.show = f.show
GROUP BY td.show, td.year, td.tony_ceremony_date
HAVING COUNT(CASE WHEN f.week_ending < td.tony_ceremony_date THEN 1 END) >= 10
   AND COUNT(CASE WHEN f.week_ending >= td.tony_ceremony_date THEN 1 END) >= 10
ORDER BY pct_change DESC;


-- Tony winners vs. non-winners aggregate comparison
-- Skills: CASE, LEFT JOIN, subquery, aggregation
SELECT 
    CASE WHEN t.show IS NOT NULL THEN 'Tony Winner' ELSE 'No Tony Win' END AS tony_status,
    COUNT(DISTINCT s.show) AS num_shows,
    ROUND(AVG(f.total_gross)::numeric / 1000000, 2) AS avg_gross_millions,
    ROUND(AVG(f.avg_cap * 100)::numeric, 1) AS avg_capacity_pct,
    ROUND(AVG(f.weeks)::numeric, 0) AS avg_weeks_running
FROM shows s
JOIN (
    SELECT show, SUM(weekly_gross) AS total_gross, AVG(pct_capacity) AS avg_cap, COUNT(*) AS weeks
    FROM financials
    WHERE week_ending >= '1995-01-01'
    GROUP BY show
) f ON s.show = f.show
LEFT JOIN tony_awards t ON s.show = t.show
GROUP BY CASE WHEN t.show IS NOT NULL THEN 'Tony Winner' ELSE 'No Tony Win' END;


-- Tony win rate by show category
-- Skills: LEFT JOIN, COUNT DISTINCT, percentage calculation
SELECT 
    s.show_category,
    COUNT(DISTINCT s.show) AS total_shows,
    COUNT(DISTINCT t.show) AS tony_winners,
    ROUND(COUNT(DISTINCT t.show) * 100.0 / COUNT(DISTINCT s.show), 1) AS win_rate_pct
FROM shows s
LEFT JOIN (
    SELECT DISTINCT show
    FROM tony_awards
    WHERE result = 'Won' AND category IN ('Best Musical', 'Best Play')
) t ON s.show = t.show
GROUP BY s.show_category
ORDER BY win_rate_pct DESC;


-- ============================================================
-- QUERY SET 4: WINDOW FUNCTIONS
-- Skills: ROW_NUMBER, LAG, AVG OVER with window frames, PARTITION BY
-- ============================================================

-- Top 3 grossing shows per year using ROW_NUMBER
-- Skills: CTEs, ROW_NUMBER, PARTITION BY
WITH yearly_gross AS (
    SELECT 
        show,
        EXTRACT(YEAR FROM week_ending)::INT AS year,
        SUM(weekly_gross) AS total_gross
    FROM financials
    WHERE week_ending >= '1995-01-01' AND week_ending < '2020-03-15'
    GROUP BY show, EXTRACT(YEAR FROM week_ending)
),
ranked AS (
    SELECT 
        show,
        year,
        ROUND(total_gross::numeric / 1000000, 2) AS gross_millions,
        ROW_NUMBER() OVER (PARTITION BY year ORDER BY total_gross DESC) AS rank
    FROM yearly_gross
)
SELECT * FROM ranked
WHERE rank <= 3
ORDER BY year, rank;


-- Hamilton's weekly gross with 8-week moving average
-- Skills: AVG OVER with window frame (ROWS BETWEEN)
SELECT 
    week_ending,
    weekly_gross,
    ROUND(AVG(weekly_gross) OVER (
        ORDER BY week_ending 
        ROWS BETWEEN 7 PRECEDING AND CURRENT ROW
    )::numeric, 0) AS moving_avg_8wk
FROM financials
WHERE show = 'Hamilton'
ORDER BY week_ending;


-- Cumulative gross for top 5 shows (running totals)
-- Skills: SUM OVER (PARTITION BY ... ORDER BY)
SELECT 
    show,
    week_ending,
    weekly_gross,
    SUM(weekly_gross) OVER (PARTITION BY show ORDER BY week_ending) AS cumulative_gross
FROM financials
WHERE show IN ('The Lion King', 'Wicked', 'Hamilton', 'The Book of Mormon', 'The Phantom of the Opera')
  AND week_ending >= '1995-01-01'
ORDER BY show, week_ending;


-- ============================================================
-- QUERY SET 5: PRODUCTION STRATEGY
-- Skills: CASE statements, date extraction, complex JOINs, subqueries
-- ============================================================

-- Opening season analysis (does launch timing affect success?)
-- Skills: CASE, EXTRACT, date casting, subquery JOIN
-- Note: opening_date is VARCHAR, must cast to date and exclude 'Still Running'
SELECT 
    CASE 
        WHEN EXTRACT(MONTH FROM s.opening_date::date) IN (9, 10, 11) THEN 'Fall (Sep-Nov)'
        WHEN EXTRACT(MONTH FROM s.opening_date::date) IN (12, 1, 2) THEN 'Winter (Dec-Feb)'
        WHEN EXTRACT(MONTH FROM s.opening_date::date) IN (3, 4, 5) THEN 'Spring (Mar-May)'
        ELSE 'Summer (Jun-Aug)'
    END AS opening_season,
    COUNT(*) AS num_shows,
    ROUND(AVG(f.total_gross)::numeric / 1000000, 2) AS avg_gross_millions,
    ROUND(AVG(f.weeks)::numeric, 0) AS avg_weeks_running
FROM shows s
JOIN (
    SELECT show, SUM(weekly_gross) AS total_gross, COUNT(*) AS weeks
    FROM financials
    GROUP BY show
) f ON s.show = f.show
WHERE s.opening_date != 'Still Running'
GROUP BY opening_season
ORDER BY avg_gross_millions DESC;


-- What do long-running shows (10+ years) have in common?
-- Skills: HAVING with COUNT, aggregation
-- (520 weeks = 10 years)
SELECT 
    s.show,
    s.show_type,
    s.show_category,
    ROUND(SUM(f.weekly_gross)::numeric / 1000000, 2) AS total_gross_millions,
    ROUND(AVG(f.pct_capacity * 100)::numeric, 1) AS avg_capacity_pct,
    ROUND(AVG(f.avg_ticket_price)::numeric, 2) AS avg_ticket_price,
    COUNT(*) AS weeks_of_data
FROM shows s
JOIN financials f ON s.show = f.show
WHERE f.week_ending >= '1995-01-01'
GROUP BY s.show, s.show_type, s.show_category
HAVING COUNT(*) >= 520
ORDER BY weeks_of_data DESC;


-- Musicals vs. Plays performance comparison
-- Skills: subquery JOIN, multiple aggregations
SELECT 
    s.show_type,
    COUNT(DISTINCT s.show) AS num_shows,
    ROUND(AVG(f.total_gross)::numeric / 1000000, 2) AS avg_gross_millions,
    ROUND(AVG(f.avg_cap * 100)::numeric, 1) AS avg_capacity_pct,
    ROUND(AVG(f.avg_price)::numeric, 2) AS avg_ticket_price,
    ROUND(AVG(f.weeks)::numeric, 0) AS avg_weeks
FROM shows s
JOIN (
    SELECT show, SUM(weekly_gross) AS total_gross, AVG(pct_capacity) AS avg_cap, 
           AVG(avg_ticket_price) AS avg_price, COUNT(*) AS weeks
    FROM financials
    WHERE week_ending >= '1995-01-01'
    GROUP BY show
) f ON s.show = f.show
GROUP BY s.show_type;


-- ============================================================
-- QUERY SET 6: COMPOSITE METRICS & RANKINGS
-- Skills: Complex CASE, multiple JOINs, tiered scoring, COALESCE, CTE
-- ============================================================

-- Multi-factor success score (financial + critical + longevity + capacity)
-- Skills: CTE, COALESCE, tiered CASE scoring, LEFT JOIN, multi-column ORDER BY
WITH show_metrics AS (
    SELECT 
        s.show,
        s.show_type,
        s.show_category,
        COALESCE(t.num_wins, 0) AS tony_wins,
        COALESCE(t.num_nominations, 0) AS tony_noms,
        COUNT(f.*) AS weeks_running,
        ROUND(AVG(f.pct_capacity * 100)::numeric, 1) AS avg_capacity,
        ROUND(SUM(f.weekly_gross)::numeric / 1000000, 2) AS total_gross_millions
    FROM shows s
    JOIN financials f ON s.show = f.show
    LEFT JOIN tony_awards t ON s.show = t.show
    WHERE f.week_ending >= '1995-01-01'
    GROUP BY s.show, s.show_type, s.show_category, t.num_wins, t.num_nominations
)
SELECT 
    show,
    show_category,
    total_gross_millions,
    avg_capacity,
    weeks_running,
    tony_wins,
    -- Score: Tony recognition + capacity tier + longevity tier
    CASE WHEN tony_wins > 0 THEN 25 ELSE 0 END +
    tony_noms * 2 +
    CASE 
        WHEN avg_capacity >= 95 THEN 20
        WHEN avg_capacity >= 90 THEN 15
        WHEN avg_capacity >= 85 THEN 10
        WHEN avg_capacity >= 80 THEN 5
        ELSE 0 
    END +
    CASE 
        WHEN weeks_running >= 1040 THEN 30
        WHEN weeks_running >= 520 THEN 25
        WHEN weeks_running >= 260 THEN 20
        WHEN weeks_running >= 104 THEN 10
        ELSE 0 
    END AS success_score
FROM show_metrics
ORDER BY success_score DESC, total_gross_millions DESC
LIMIT 20;


-- Tony Award winners ranked by total gross revenue
-- Skills: 3-table JOIN, GROUP BY, aggregate functions, type casting
SELECT 
    s.show,
    s.show_category,
    t.year AS tony_year,
    t.category AS tony_category,
    t.num_nominations,
    t.num_wins,
    ROUND(SUM(f.weekly_gross)::numeric / 1000000, 2) AS total_gross_millions
FROM shows s
JOIN tony_awards t ON s.show = t.show
JOIN financials f ON s.show = f.show
GROUP BY s.show, s.show_category, t.year, t.category, t.num_nominations, t.num_wins
ORDER BY total_gross_millions DESC;


-- Top 15 shows overall (final rankings summary)
-- Skills: 3-table LEFT JOIN, multiple aggregations, COALESCE
SELECT 
    s.show,
    s.show_type,
    s.show_category,
    ROUND(SUM(f.weekly_gross)::numeric / 1000000, 2) AS total_gross_millions,
    ROUND(AVG(f.pct_capacity * 100)::numeric, 1) AS avg_capacity_pct,
    ROUND(AVG(f.avg_ticket_price)::numeric, 2) AS avg_ticket_price,
    COUNT(*) AS weeks_running,
    COALESCE(t.num_wins, 0) AS tony_wins
FROM shows s
JOIN financials f ON s.show = f.show
LEFT JOIN tony_awards t ON s.show = t.show
WHERE f.week_ending >= '1995-01-01'
GROUP BY s.show, s.show_type, s.show_category, t.num_wins
ORDER BY total_gross_millions DESC
LIMIT 15;


-- ============================================================
-- CHART DATA EXPORTS (for Excel visualization)
-- ============================================================

-- Capacity vs. Weeks Running scatterplot data (all 145 shows)
-- Business question: Is sustained capacity the best predictor of longevity?
SELECT 
    s.show,
    s.show_type,
    s.show_category,
    COUNT(*) AS total_weeks,
    ROUND(AVG(f.pct_capacity)::numeric * 100, 1) AS avg_capacity_pct,
    ROUND(SUM(f.weekly_gross)::numeric / 1000000, 2) AS total_gross_millions
FROM shows s
JOIN financials f ON s.show = f.show
WHERE f.week_ending >= '1995-01-01'
GROUP BY s.show, s.show_type, s.show_category
ORDER BY total_weeks DESC;
