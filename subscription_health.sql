/* =============================================================
   정기구독 건전성 분석 — 통합 SQL
   Script-20: LTV / 평균 유지회차 / 월별 모수 증감 (전년동기 비교)

   분석 기준
   ─ 당기       : 2025-09-23 ~ 2026-05-13 (약 8개월)
   ─ 전년동기   : 2024-09-23 ~ 2025-05-13 (동일 8개월 윈도우)
   ─ LTV 기준   : 실결제액 합산 (price + adjustment_price - refund_amount)
   ─ 정지 기간  : 결제 미발생 → 회차·LTV 계산에서 자동 제외
   ─ 8개월 캡   : 양 코호트 동일 관측 기간으로 공정 비교

   결과 구조 (분석_구분 컬럼으로 구분)
   ① LTV_회차_요약   — 기간별 1행 (당기 / 전년동기)
   ② 회차_분포       — 기간 × 회차 구간별 분포
   ③ 월별_모수_증감  — 월별 신규·정지·해지·순증감 (전년동기 나란히)
   ============================================================= */

WITH

/* ─────────────────────────────────────────
   STEP 1. 구독별 첫 결제일
   ───────────────────────────────────────── */
first_paid AS (
    SELECT
        og.regular_order_id,
        MIN(oi.paid_at AT TIME ZONE 'Asia/Seoul') AS first_paid_kst
    FROM orders_ordergroup og
    JOIN orders_orderitem oi
        ON oi.group_id = og.id
    WHERE og.regular_order_id IS NOT NULL
      AND oi.paid_at    IS NOT NULL
      AND oi.cancelled_at IS NULL
    GROUP BY 1
),

/* ─────────────────────────────────────────
   STEP 2. 코호트 분류 (당기 / 전년동기)
   ───────────────────────────────────────── */
cohort AS (
    SELECT
        regular_order_id,
        first_paid_kst,
        CASE
            WHEN first_paid_kst::date
                 BETWEEN DATE '2025-09-23' AND DATE '2026-05-13'
                THEN '당기 (25.09~26.05)'
            WHEN first_paid_kst::date
                 BETWEEN DATE '2024-09-23' AND DATE '2025-05-13'
                THEN '전년동기 (24.09~25.05)'
        END AS 기간_구분
    FROM first_paid
    WHERE first_paid_kst::date
          BETWEEN DATE '2024-09-23' AND DATE '2026-05-13'
),

/* ─────────────────────────────────────────
   STEP 3. 구독별 LTV + 유지회차
           (첫 결제일 기준 8개월=243일 이내 결제만)
   ───────────────────────────────────────── */
sub_metrics AS (
    SELECT
        c.regular_order_id,
        c.기간_구분,
        SUM(
            oi.price
            + COALESCE(oi.adjustment_price, 0)
            - COALESCE(oi.refund_amount,    0)
        )                     AS ltv_amount,
        COUNT(DISTINCT og.id) AS paid_rounds,
        BOOL_OR(oi.is_100won) AS has_100won   -- 100원 프로모션 포함 여부
    FROM cohort c
    JOIN orders_ordergroup og
        ON og.regular_order_id = c.regular_order_id
    JOIN orders_orderitem oi
        ON oi.group_id = og.id
    WHERE oi.paid_at    IS NOT NULL
      AND oi.cancelled_at IS NULL
      AND (oi.paid_at AT TIME ZONE 'Asia/Seoul')
              <= c.first_paid_kst + INTERVAL '243 days'
    GROUP BY 1, 2
),

/* ─────────────────────────────────────────
   STEP 4-A. LTV + 회차 요약 집계
   ───────────────────────────────────────── */
summary_agg AS (
    SELECT
        기간_구분,
        COUNT(*)                                                               AS 구독수,

        -- LTV
        ROUND(AVG(ltv_amount))                                                 AS 평균_LTV,
        ROUND(PERCENTILE_CONT(0.5)
              WITHIN GROUP (ORDER BY ltv_amount))                              AS 중앙값_LTV,
        ROUND(AVG(ltv_amount)
              FILTER (WHERE NOT has_100won))                                   AS 평균_LTV_프로모제외,

        -- 유지회차
        ROUND(AVG(paid_rounds), 2)                                             AS 평균_유지회차,
        ROUND(PERCENTILE_CONT(0.5)
              WITHIN GROUP (ORDER BY paid_rounds::float))                      AS 중앙값_회차,
        ROUND(PERCENTILE_CONT(0.25)
              WITHIN GROUP (ORDER BY paid_rounds::float))                      AS Q1_회차,
        ROUND(PERCENTILE_CONT(0.75)
              WITHIN GROUP (ORDER BY paid_rounds::float))                      AS Q3_회차,

        -- 1회 이탈
        COUNT(*) FILTER (WHERE paid_rounds = 1)                                AS 1회_이탈수,
        ROUND(
            COUNT(*) FILTER (WHERE paid_rounds = 1)::numeric
            / NULLIF(COUNT(*), 0) * 100, 1
        )                                                                      AS 1회_이탈율_pct
    FROM sub_metrics
    GROUP BY 1
),

/* ─────────────────────────────────────────
   STEP 4-B. 회차 구간별 분포
   ───────────────────────────────────────── */
round_dist AS (
    SELECT
        기간_구분,
        CASE
            WHEN paid_rounds = 1              THEN '1회 이탈'
            WHEN paid_rounds BETWEEN 2 AND 3  THEN '2~3회'
            WHEN paid_rounds BETWEEN 4 AND 6  THEN '4~6회'
            WHEN paid_rounds BETWEEN 7 AND 12 THEN '7~12회'
            WHEN paid_rounds > 12             THEN '12회 초과'
        END                       AS 회차_구간,
        CASE
            WHEN paid_rounds = 1              THEN 1
            WHEN paid_rounds BETWEEN 2 AND 3  THEN 2
            WHEN paid_rounds BETWEEN 4 AND 6  THEN 3
            WHEN paid_rounds BETWEEN 7 AND 12 THEN 4
            WHEN paid_rounds > 12             THEN 5
        END                       AS 회차_순서,
        COUNT(*)                  AS 구독수,
        ROUND(
            COUNT(*)::numeric
            / NULLIF(SUM(COUNT(*)) OVER (PARTITION BY 기간_구분), 0) * 100, 1
        )                         AS 비중_pct
    FROM sub_metrics
    GROUP BY 1, 2, 3
),

/* ─────────────────────────────────────────
   STEP 5. 월별 모수 증감
   ───────────────────────────────────────── */
monthly_new AS (
    -- 신규: 구독별 첫 결제 발생 월
    SELECT
        DATE_TRUNC('month',
            MIN(oi.paid_at AT TIME ZONE 'Asia/Seoul')
        )::date          AS month_start,
        og.regular_order_id
    FROM orders_ordergroup og
    JOIN orders_orderitem oi ON oi.group_id = og.id
    WHERE og.regular_order_id IS NOT NULL
      AND oi.paid_at    IS NOT NULL
      AND oi.cancelled_at IS NULL
    GROUP BY 2
),

new_agg AS (
    SELECT month_start, COUNT(*) AS 신규
    FROM monthly_new
    WHERE month_start BETWEEN DATE '2024-09-01' AND DATE '2026-05-01'
    GROUP BY 1
),

paused_agg AS (
    -- 정지 (paused + auto_paused)
    SELECT
        DATE_TRUNC('month',
            paused_at AT TIME ZONE 'Asia/Seoul'
        )::date          AS month_start,
        COUNT(*)         AS 정지
    FROM regular_orders_regularorder
    WHERE status IN ('paused', 'auto_paused')
      AND paused_at IS NOT NULL
      AND (paused_at AT TIME ZONE 'Asia/Seoul')::date
              BETWEEN DATE '2024-09-01' AND DATE '2026-05-31'
    GROUP BY 1
),

terminated_agg AS (
    -- 해지
    SELECT
        DATE_TRUNC('month',
            terminated_at AT TIME ZONE 'Asia/Seoul'
        )::date          AS month_start,
        COUNT(*)         AS 해지
    FROM regular_orders_regularorder
    WHERE status = 'terminated'
      AND terminated_at IS NOT NULL
      AND (terminated_at AT TIME ZONE 'Asia/Seoul')::date
              BETWEEN DATE '2024-09-01' AND DATE '2026-05-31'
    GROUP BY 1
),

month_series AS (
    SELECT generate_series(
        DATE '2024-09-01',
        DATE '2026-05-01',
        INTERVAL '1 month'
    )::date AS month_start
),

monthly_flow AS (
    SELECT
        m.month_start,
        TO_CHAR(m.month_start, 'YYYY.MM')               AS 월,
        CASE WHEN m.month_start >= DATE '2025-09-01'
             THEN '당기' ELSE '전년동기' END             AS 기간_구분,
        EXTRACT(MONTH FROM m.month_start)::int           AS 월_번호,
        COALESCE(n.신규, 0)                              AS 신규,
        COALESCE(p.정지, 0)                              AS 정지,
        COALESCE(t.해지, 0)                              AS 해지,
        COALESCE(n.신규, 0)
            - COALESCE(p.정지, 0)
            - COALESCE(t.해지, 0)                        AS 순증감
    FROM month_series m
    LEFT JOIN new_agg        n ON n.month_start = m.month_start
    LEFT JOIN paused_agg     p ON p.month_start = m.month_start
    LEFT JOIN terminated_agg t ON t.month_start = m.month_start
),

monthly_with_cumsum AS (
    SELECT
        *,
        SUM(순증감) OVER (
            PARTITION BY 기간_구분
            ORDER BY month_start
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS 누적_순증감
    FROM monthly_flow
)

/* ═════════════════════════════════════════
   FINAL OUTPUT — UNION ALL 3개 분석 블록
   분석_구분 컬럼으로 필터해서 사용하세요
   ═════════════════════════════════════════ */

-- ① LTV + 회차 요약 (기간별 1행)
SELECT
    'LTV_회차_요약'      AS 분석_구분,
    기간_구분,
    NULL                 AS 월,
    NULL::int            AS 월_번호,
    NULL                 AS 회차_구간,
    구독수,
    평균_LTV             AS 값_A,
    중앙값_LTV           AS 값_B,
    평균_LTV_프로모제외  AS 값_C,
    평균_유지회차        AS 값_D,
    중앙값_회차          AS 값_E,
    Q1_회차              AS 값_F,
    Q3_회차              AS 값_G,
    1회_이탈수           AS 값_H,
    1회_이탈율_pct       AS 값_I,
    NULL::bigint         AS 값_J,   -- 신규
    NULL::bigint         AS 값_K,   -- 정지
    NULL::bigint         AS 값_L,   -- 해지
    NULL::bigint         AS 값_M,   -- 순증감
    NULL::numeric        AS 값_N    -- 누적 순증감
FROM summary_agg

UNION ALL

-- ② 회차 구간별 분포 (기간 × 구간별 행)
SELECT
    '회차_분포'          AS 분석_구분,
    기간_구분,
    NULL                 AS 월,
    회차_순서            AS 월_번호,
    회차_구간,
    구독수,
    비중_pct             AS 값_A,
    NULL::numeric        AS 값_B,
    NULL::numeric        AS 값_C,
    NULL::numeric        AS 값_D,
    NULL::numeric        AS 값_E,
    NULL::numeric        AS 값_F,
    NULL::numeric        AS 값_G,
    NULL::bigint         AS 값_H,
    NULL::numeric        AS 값_I,
    NULL::bigint         AS 값_J,
    NULL::bigint         AS 값_K,
    NULL::bigint         AS 값_L,
    NULL::bigint         AS 값_M,
    NULL::numeric        AS 값_N
FROM round_dist

UNION ALL

-- ③ 월별 모수 증감 (월별 행)
SELECT
    '월별_모수_증감'     AS 분석_구분,
    기간_구분,
    월,
    월_번호,
    NULL                 AS 회차_구간,
    NULL::bigint         AS 구독수,
    NULL::numeric        AS 값_A,
    NULL::numeric        AS 값_B,
    NULL::numeric        AS 값_C,
    NULL::numeric        AS 값_D,
    NULL::numeric        AS 값_E,
    NULL::numeric        AS 값_F,
    NULL::numeric        AS 값_G,
    NULL::bigint         AS 값_H,
    NULL::numeric        AS 값_I,
    신규                 AS 값_J,
    정지                 AS 값_K,
    해지                 AS 값_L,
    순증감               AS 값_M,
    누적_순증감          AS 값_N
FROM monthly_with_cumsum

ORDER BY
    분석_구분,
    기간_구분 DESC,   -- 당기 먼저
    월_번호   NULLS FIRST;

/* ─────────────────────────────────────────
   컬럼 가이드
   ─────────────────────────────────────────
   ① LTV_회차_요약
      값_A  평균 LTV (원)
      값_B  중앙값 LTV
      값_C  평균 LTV (100원 프로모 제외)
      값_D  평균 유지회차
      값_E  중앙값 회차
      값_F  Q1 회차 (하위 25%)
      값_G  Q3 회차 (상위 25%)
      값_H  1회 이탈 구독수
      값_I  1회 이탈율 (%)

   ② 회차_분포
      회차_구간  1회/2~3회/4~6회/7~12회/12회초과
      구독수     해당 구간 구독 건수
      값_A       비중 (%)

   ③ 월별_모수_증감
      값_J  신규 구독수
      값_K  정지 건수
      값_L  해지 건수
      값_M  순증감 (신규-정지-해지)
      값_N  기간 내 누적 순증감
   ───────────────────────────────────────── */
