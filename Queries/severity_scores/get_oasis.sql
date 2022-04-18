-- ------------------------------------------------------------------
-- Code taken from: https://github.com/MIT-LCP/mimic-code/tree/main/mimic-iii/concepts/severityscores
-- Description: This query provides a useful set information about the patients severity scores (SAPSII).
-- Extracted number of rows: 61532
-- ------------------------------------------------------------------

DROP TABLE IF EXISTS mortpred.oasis;
CREATE TABLE mortpred.oasis as

-- ------------------------------------------------------------------
-- Title: Oxford Acute Severity of Illness Score (oasis)
-- This query extracts the Oxford acute severity of illness score.
-- This score is a measure of severity of illness for patients in the ICU.
-- The score is calculated on the first day of each ICU patients' stay.
-- ------------------------------------------------------------------

-- Reference for OASIS:
--    Johnson, Alistair EW, Andrew A. Kramer, and Gari D. Clifford.
--    "A new severity of illness scale using a subset of acute physiology and chronic health evaluation data elements shows comparable predictive accuracy*."
--    Critical care medicine 41, no. 7 (2013): 1711-1718.

-- Variables used in OASIS:
--  Heart rate, GCS, MAP, Temperature, Respiratory rate, Ventilation status (sourced FROM `physionet-data.mimiciii_clinical.chartevents`)
--  Urine output (sourced from OUTPUTEVENTS)
--  Elective surgery (sourced FROM `physionet-data.mimiciii_clinical.admissions` and SERVICES)
--  Pre-ICU in-hospital length of stay (sourced FROM `physionet-data.mimiciii_clinical.admissions` and ICUSTAYS)
--  Age (sourced FROM `physionet-data.mimiciii_clinical.patients`)

-- The following views are required to run this query:
--  1) urine_output_first_day - generated by urine-output-first-day.sql
--  2) vent_first_day - generated by ventilated-first-day.sql
--  3) vitals_first_day - generated by vitals-first-day.sql
--  4) gcs_first_day - generated by gcs-first-day.sql


-- Regarding missing values:
--  The ventilation flag is always 0/1. It cannot be missing, since VENT=0 if no data is found for vent settings.

-- Note:
--  The score is calculated for *all* ICU patients, with the assumption that the user will subselect appropriate ICUSTAY_IDs.
--  For example, the score is calculated for neonates, but it is likely inappropriate to actually use the score values for these patients.


with surgflag as
(
  select ie.icustay_id
    , max(case
        when lower(curr_service) like '%surg%' then 1
        when curr_service = 'ORTHO' then 1
    else 0 end) as surgical
  FROM mimiciii.icustays ie
  left join mimiciii.services se
    on ie.hadm_id = se.hadm_id
    and se.transfertime < (ie.intime + INTERVAL '1 day')
  group by ie.icustay_id
)
, cohort as
(
select ie.subject_id, ie.hadm_id, ie.icustay_id
      , ie.intime
      , ie.outtime
      , adm.deathtime
      , (((DATE_PART('day', ie.intime - adm.admittime)) * 24 + DATE_PART('hour', ie.intime - adm.admittime)) * 60 + DATE_PART('minute', ie.intime - adm.admittime)) as preiculos
      , (DATE_PART('year', ie.intime) - DATE_PART('year', pat.dob)) as age
      , gcs.mingcs
      , vital.heartrate_max
      , vital.heartrate_min
      , vital.meanbp_max
      , vital.meanbp_min
      , vital.resprate_max
      , vital.resprate_min
      , vital.tempc_max
      , vital.tempc_min
      , vent.vent as mechvent
      , uo.urineoutput

      , case
          when adm.ADMISSION_TYPE = 'ELECTIVE' and sf.surgical = 1
            then 1
          when adm.ADMISSION_TYPE is null or sf.surgical is null
            then null
          else 0
        end as electivesurgery

      -- age group
      , case
        when (DATE_PART('year', ie.intime) - DATE_PART('year', pat.dob)) <= 1 then 'neonate'
        when (DATE_PART('year', ie.intime) - DATE_PART('year', pat.dob)) <= 15 then 'middle'
        else 'adult' end as icustay_age_group

      -- mortality flags
      , case
          when adm.deathtime between ie.intime and ie.outtime
            then 1
          when adm.deathtime <= ie.intime -- sometimes there are typographical errors in the death date
            then 1
          when adm.dischtime <= ie.outtime and adm.discharge_location = 'DEAD/EXPIRED'
            then 1
          else 0 end
        as icustay_expire_flag
      , adm.hospital_expire_flag
FROM mimiciii.icustays ie
inner join mimiciii.admissions adm
  on ie.hadm_id = adm.hadm_id
inner join mimiciii.patients pat
  on ie.subject_id = pat.subject_id
left join surgflag sf
  on ie.icustay_id = sf.icustay_id
-- join to custom tables to get more data....
left join mortpred.gcsfirsticu gcs
  on ie.icustay_id = gcs.icustay_id
left join mortpred.vitalsfirsticu vital
  on ie.icustay_id = vital.icustay_id
left join mortpred.urineoutput uo
  on ie.icustay_id = uo.icustay_id
left join mortpred.ventfirsticu vent
  on ie.icustay_id = vent.icustay_id
)
, scorecomp as
(
select co.subject_id, co.hadm_id, co.icustay_id
, co.icustay_age_group
, co.icustay_expire_flag
, co.hospital_expire_flag

-- Below code calculates the component scores needed for oasis
, case when preiculos is null then null
     when preiculos < 10.2 then 5
     when preiculos < 297 then 3
     when preiculos < 1440 then 0
     when preiculos < 18708 then 1
     else 2 end as preiculos_score
,  case when age is null then null
      when age < 24 then 0
      when age <= 53 then 3
      when age <= 77 then 6
      when age <= 89 then 9
      when age >= 90 then 7
      else 0 end as age_score
,  case when mingcs is null then null
      when mingcs <= 7 then 10
      when mingcs < 14 then 4
      when mingcs = 14 then 3
      else 0 end as gcs_score
,  case when heartrate_max is null then null
      when heartrate_max > 125 then 6
      when heartrate_min < 33 then 4
      when heartrate_max >= 107 and heartrate_max <= 125 then 3
      when heartrate_max >= 89 and heartrate_max <= 106 then 1
      else 0 end as heartrate_score
,  case when meanbp_min is null then null
      when meanbp_min < 20.65 then 4
      when meanbp_min < 51 then 3
      when meanbp_max > 143.44 then 3
      when meanbp_min >= 51 and meanbp_min < 61.33 then 2
      else 0 end as meanbp_score
,  case when resprate_min is null then null
      when resprate_min <   6 then 10
      when resprate_max >  44 then  9
      when resprate_max >  30 then  6
      when resprate_max >  22 then  1
      when resprate_min <  13 then 1 else 0
      end as resprate_score
,  case when tempc_max is null then null
      when tempc_max > 39.88 then 6
      when tempc_min >= 33.22 and tempc_min <= 35.93 then 4
      when tempc_max >= 33.22 and tempc_max <= 35.93 then 4
      when tempc_min < 33.22 then 3
      when tempc_min > 35.93 and tempc_min <= 36.39 then 2
      when tempc_max >= 36.89 and tempc_max <= 39.88 then 2
      else 0 end as temp_score
,  case when UrineOutput is null then null
      when UrineOutput < 671.09 then 10
      when UrineOutput > 6896.80 then 8
      when UrineOutput >= 671.09
       and UrineOutput <= 1426.99 then 5
      when UrineOutput >= 1427.00
       and UrineOutput <= 2544.14 then 1
      else 0 end as urineoutput_score
,  case when mechvent is null then null
      when mechvent = 1 then 9
      else 0 end as mechvent_score
,  case when electivesurgery is null then null
      when electivesurgery = 1 then 0
      else 6 end as electivesurgery_score


-- The below code gives the component associated with each score
-- This is not needed to calculate oasis, but provided for user convenience.
-- If both the min/max are in the normal range (score of 0), then the average value is stored.
, preiculos
, age
, mingcs as gcs
,  case when heartrate_max is null then null
      when heartrate_max > 125 then heartrate_max
      when heartrate_min < 33 then heartrate_min
      when heartrate_max >= 107 and heartrate_max <= 125 then heartrate_max
      when heartrate_max >= 89 and heartrate_max <= 106 then heartrate_max
      else (heartrate_min+heartrate_max)/2 end as heartrate
,  case when meanbp_min is null then null
      when meanbp_min < 20.65 then meanbp_min
      when meanbp_min < 51 then meanbp_min
      when meanbp_max > 143.44 then meanbp_max
      when meanbp_min >= 51 and meanbp_min < 61.33 then meanbp_min
      else (meanbp_min+meanbp_max)/2 end as meanbp
,  case when resprate_min is null then null
      when resprate_min <   6 then resprate_min
      when resprate_max >  44 then resprate_max
      when resprate_max >  30 then resprate_max
      when resprate_max >  22 then resprate_max
      when resprate_min <  13 then resprate_min
      else (resprate_min+resprate_max)/2 end as resprate
,  case when tempc_max is null then null
      when tempc_max > 39.88 then tempc_max
      when tempc_min >= 33.22 and tempc_min <= 35.93 then tempc_min
      when tempc_max >= 33.22 and tempc_max <= 35.93 then tempc_max
      when tempc_min < 33.22 then tempc_min
      when tempc_min > 35.93 and tempc_min <= 36.39 then tempc_min
      when tempc_max >= 36.89 and tempc_max <= 39.88 then tempc_max
      else (tempc_min+tempc_max)/2 end as temp
,  UrineOutput
,  mechvent
,  electivesurgery
from cohort co
)
, score as
(
select s.*
    , coalesce(age_score,0)
    + coalesce(preiculos_score,0)
    + coalesce(gcs_score,0)
    + coalesce(heartrate_score,0)
    + coalesce(meanbp_score,0)
    + coalesce(resprate_score,0)
    + coalesce(temp_score,0)
    + coalesce(urineoutput_score,0)
    + coalesce(mechvent_score,0)
    + coalesce(electivesurgery_score,0)
    as oasis
from scorecomp s
)
select
  subject_id, hadm_id, icustay_id
  , icustay_age_group
  , hospital_expire_flag
  , icustay_expire_flag
  , oasis
  -- Calculate the probability of in-hospital mortality
  , 1 / (1 + exp(- (-6.1746 + 0.1275*(oasis) ))) as oasis_PROB
  , age, age_score
  , preiculos, preiculos_score
  , gcs, gcs_score
  , heartrate, heartrate_score
  , meanbp, meanbp_score
  , resprate, resprate_score
  , temp, temp_score
  , urineoutput, urineoutput_score
  , mechvent, mechvent_score
  , electivesurgery, electivesurgery_score
from score
order by icustay_id;