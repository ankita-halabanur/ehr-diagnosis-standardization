CREATE DATABASE ehr_project;
USE ehr_project;
USE ehr_project;

DROP TABLE IF EXISTS cleaned_ehr_data;

CREATE TABLE cleaned_ehr_data (
    patientunitstayid           BIGINT,
    patienthealthsystemstayid   BIGINT,
    gender                      VARCHAR(20),
    age                         VARCHAR(10),
    ethnicity                   VARCHAR(50),
    hospitalid                  INT,
    wardid                      INT,
    apacheadmissiondx           TEXT,
    admissionheight             FLOAT,
    hospitaladmittime24         VARCHAR(20),
    hospitaladmitoffset         INT,
    hospitaladmitsource         VARCHAR(100),
    hospitaldischargeyear       INT,
    hospitaldischargetime24     VARCHAR(20),
    hospitaldischargeoffset     INT,
    hospitaldischargelocation   VARCHAR(100),
    hospitaldischargestatus     VARCHAR(20),
    unittype                    VARCHAR(100),
    unitadmittime24             VARCHAR(20),
    unitadmitsource             VARCHAR(100),
    unitvisitnumber             INT,
    unitstaytype                VARCHAR(50),
    admissionweight             FLOAT,
    dischargeweight             FLOAT,
    unitdischargetime24         VARCHAR(20),
    unitdischargeoffset         INT,
    unitdischargelocation       VARCHAR(100),
    unitdischargestatus         VARCHAR(20),
    uniquepid                   VARCHAR(20),
    diagnosis_cleaned           TEXT,
    icd10_code                  VARCHAR(20),
    hospitaladmittime24_parsed  DATETIME,
    admit_date                  DATE
);

SET GLOBAL local_infile = 1;
USE ehr_project;

LOAD DATA LOCAL INFILE 'C:/Users/RAHUL/Documents/EHR project/cleaned_ehr_data.csv'
INTO TABLE cleaned_ehr_data
FIELDS TERMINATED BY ','
ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;
SELECT COUNT(*) FROM cleaned_ehr_data;
SELECT * FROM cleaned_ehr_data LIMIT 5;

-- Query 1: Diagnosis Frequency & ICD-10 Coverage Rate

SELECT
    diagnosis_cleaned,
    icd10_code,
    COUNT(*) AS total_cases,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct_of_total,
    SUM(CASE WHEN icd10_code IS NOT NULL THEN 1 ELSE 0 END) AS mapped_cases,
    ROUND(
        SUM(CASE WHEN icd10_code IS NOT NULL THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
        1
    ) AS mapping_coverage_pct
FROM cleaned_ehr_data
GROUP BY diagnosis_cleaned, icd10_code
ORDER BY total_cases DESC
LIMIT 15;

-- Query 2: Mortality Rate by Diagnosis

SELECT
    diagnosis_cleaned,
    icd10_code,
    COUNT(*) AS total_patients,
    SUM(CASE WHEN hospitaldischargestatus = 'Expired' THEN 1 ELSE 0 END) AS deaths,
    SUM(CASE WHEN hospitaldischargestatus = 'Alive' THEN 1 ELSE 0 END) AS survived,
    ROUND(
        SUM(CASE WHEN hospitaldischargestatus = 'Expired' THEN 1 ELSE 0 END)
        * 100.0 / COUNT(*),
        1
    ) AS mortality_rate_pct
FROM cleaned_ehr_data
WHERE hospitaldischargestatus IN ('Expired', 'Alive')
  AND icd10_code IS NOT NULL
GROUP BY diagnosis_cleaned, icd10_code
HAVING COUNT(*) >= 5
ORDER BY mortality_rate_pct DESC
LIMIT 10;

-- Query 3: Gender & Ethnicity Distribution per Diagnosis

SELECT
    diagnosis_cleaned,
    COUNT(*) AS total,
    SUM(CASE WHEN gender = 'female' THEN 1 ELSE 0 END) AS female_count,
    SUM(CASE WHEN gender = 'male' THEN 1 ELSE 0 END) AS male_count,
    SUM(CASE WHEN ethnicity = 'Caucasian' THEN 1 ELSE 0 END) AS caucasian,
    SUM(CASE WHEN ethnicity = 'African American' THEN 1 ELSE 0 END) AS african_american,
    SUM(CASE WHEN ethnicity = 'Hispanic' THEN 1 ELSE 0 END) AS hispanic,
    SUM(CASE WHEN ethnicity = 'Asian' THEN 1 ELSE 0 END) AS asian,
    ROUND(
        SUM(CASE WHEN gender = 'female' THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
        1
    ) AS female_pct
FROM cleaned_ehr_data
WHERE diagnosis_cleaned != 'nan'
GROUP BY diagnosis_cleaned
HAVING COUNT(*) >= 10
ORDER BY total DESC
LIMIT 12;

-- Query 4: Average ICU Length of Stay by Diagnosis

WITH los_base AS (
    SELECT
        diagnosis_cleaned,
        icd10_code,
        (unitdischargeoffset - hospitaladmitoffset) / 60.0 AS icu_los_hours,
        hospitaldischargestatus
    FROM cleaned_ehr_data
    WHERE unitdischargeoffset IS NOT NULL
      AND hospitaladmitoffset IS NOT NULL
      AND diagnosis_cleaned != 'nan'
),
summary AS (
    SELECT
        diagnosis_cleaned,
        icd10_code,
        COUNT(*) AS patient_count,
        ROUND(AVG(icu_los_hours), 1) AS avg_icu_los_hrs,
        ROUND(MIN(icu_los_hours), 1) AS min_los_hrs,
        ROUND(MAX(icu_los_hours), 1) AS max_los_hrs,
        ROUND(AVG(AVG(icu_los_hours)) OVER (), 1) AS overall_avg_los_hrs
    FROM los_base
    GROUP BY diagnosis_cleaned, icd10_code
    HAVING COUNT(*) >= 5
)
SELECT
    *,
    ROUND(avg_icu_los_hrs - overall_avg_los_hrs, 1) AS deviation_from_avg,
    RANK() OVER (ORDER BY avg_icu_los_hrs DESC) AS los_rank
FROM summary
ORDER BY avg_icu_los_hrs DESC
LIMIT 10;

-- Query 5: Monthly Admission Trend + Rolling 3-Month Average

WITH monthly AS (
    SELECT
        DATE_FORMAT(admit_date, '%Y-%m') AS admit_month,
        diagnosis_cleaned,
        COUNT(*) AS admissions
    FROM cleaned_ehr_data
    WHERE admit_date IS NOT NULL
      AND diagnosis_cleaned IN (
          'sepsis', 'congestive heart failure', 'gi bleeding',
          'diabetic ketoacidosis', 'myocardial infarction'
      )
    GROUP BY admit_month, diagnosis_cleaned
)
SELECT
    admit_month,
    diagnosis_cleaned,
    admissions,
    ROUND(
        AVG(admissions) OVER (
            PARTITION BY diagnosis_cleaned
            ORDER BY admit_month
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ),
        1
    ) AS rolling_3mo_avg
FROM monthly
ORDER BY diagnosis_cleaned, admit_month;

-- Query 6: 30-Day Readmission Risk Flag by Diagnosis

WITH stay_ordered AS (
    SELECT
        uniquepid,
        diagnosis_cleaned,
        icd10_code,
        admit_date,
        LAG(admit_date) OVER (
            PARTITION BY uniquepid
            ORDER BY admit_date
        ) AS prev_admit_date
    FROM cleaned_ehr_data
),
readmission_flagged AS (
    SELECT
        *,
        DATEDIFF(admit_date, prev_admit_date) AS days_since_last_admit,
        CASE
            WHEN DATEDIFF(admit_date, prev_admit_date) <= 30 THEN 1
            ELSE 0
        END AS is_readmission_30d
    FROM stay_ordered
    WHERE prev_admit_date IS NOT NULL
)
SELECT
    diagnosis_cleaned,
    icd10_code,
    COUNT(*) AS total_revisits,
    SUM(is_readmission_30d) AS readmissions_30d,
    ROUND(SUM(is_readmission_30d) * 100.0 / COUNT(*), 1) AS readmission_rate_pct
FROM readmission_flagged
GROUP BY diagnosis_cleaned, icd10_code
HAVING COUNT(*) >= 5
ORDER BY readmission_rate_pct DESC
LIMIT 10;