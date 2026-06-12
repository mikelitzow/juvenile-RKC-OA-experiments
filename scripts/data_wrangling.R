# ============================================================
# data_wrangling.R
#
# Combine juvenile red king crab (RKC) survival and wet-mass
# data from three ocean-acidification experiments into shared,
# tidy data frames for meta-analysis.
#
#   * 2010-2011  Long  et al. 2013 (PLoS ONE)
#   * 2012-2013  Swiney et al. 2017 (ICES JMS)
#   * 2024-2025  unpublished
#
# Run from the project root.  Output CSVs are written to
# data/combined/.
# ============================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(stringr)
  library(lubridate)
  library(purrr)
})

dir.create("data/combined", showWarnings = FALSE, recursive = TRUE)

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

# Standardise treatment_pH labels across experiments.
std_pH <- function(x) {
  x <- str_trim(as.character(x))
  case_when(
    str_detect(tolower(x), "^a") | x %in% c("Control", "Ambient", "ambient") ~ "ambient",
    str_detect(x, "7\\.5\\b|^pH ?7\\.5$|pH7\\.5")   ~ "pH 7.5",
    str_detect(x, "7\\.55") ~ "pH 7.55",
    str_detect(x, "7\\.65") ~ "pH 7.65",
    str_detect(x, "7\\.8\\b|^pH ?7\\.8$|pH7\\.8")   ~ "pH 7.8",
    str_detect(x, "7\\.85") ~ "pH 7.85",
    TRUE ~ x
  )
}

# Standardise temperature treatment labels (offsets from ambient).
std_temp <- function(x) {
  x <- str_trim(as.character(x))
  case_when(
    x %in% c("A", "ambient", "Ambient") | x == "ambient"            ~ "ambient",
    str_detect(x, "\\+ ?2")                                          ~ "+2C",
    str_detect(x, "\\+ ?3")                                          ~ "+3C",
    str_detect(x, "\\+ ?4")                                          ~ "+4C",
    TRUE ~ x
  )
}

# Parse 2024 Treatment strings of the form "pH 7.55- +3C", "A-A", etc.
parse_treatment_24 <- function(x) {
  pieces <- str_split_fixed(x, "-", 2)
  ph_str   <- str_trim(pieces[, 1])
  temp_str <- str_trim(pieces[, 2])
  tibble(
    treatment_pH   = std_pH(ph_str),
    treatment_temp = std_temp(temp_str)
  )
}

# ============================================================
# 1.  SURVIVAL
# ============================================================

# ------------------------------------------------------------
# 1a. 2010-2011 (Long et al. 2013)
# Survival for R 2010.csv is stacked: a 192-day Control series,
# a 192-day pH 7.8 series, and a 96-day pH 7.5 series.  Treatment
# is encoded by three indicator columns.
# ------------------------------------------------------------
surv_2010 <- read_csv(
  "data/2010-2011/Survival for R 2010.csv",
  col_names = c("day", "n_alive", "Control", "pH7.8", "pH7.5"),
  skip      = 1,
  show_col_types = FALSE
) |>
  mutate(
    treatment_pH = case_when(
      Control == 1 ~ "ambient",
      `pH7.8`  == 1 ~ "pH 7.8",
      `pH7.5`  == 1 ~ "pH 7.5"
    ),
    treatment_temp = "ambient",
    experiment     = "2010-2011",
    n_initial      = 30L
  ) |>
  select(experiment, treatment_pH, treatment_temp, day, n_alive, n_initial)

# ------------------------------------------------------------
# 1b. 2012-2013 (Swiney et al. 2017)
# ------------------------------------------------------------
surv_2012 <- read_csv(
  "data/2012-2013/33529_RACE_2012-2013_survival.csv",
  show_col_types = FALSE
) |>
  rename(
    day            = `Experimental Day`,
    treatment_pH   = `Treatment pH`,
    treatment_temp = `Treatment temp C`,
    n_alive        = `Number alive`,
    n_initial      = `Initial number`
  ) |>
  mutate(
    treatment_pH   = std_pH(treatment_pH),
    treatment_temp = std_temp(treatment_temp),
    experiment     = "2012-2013"
  ) |>
  select(experiment, treatment_pH, treatment_temp, day, n_alive, n_initial)

# ------------------------------------------------------------
# 1c. 2024-2025 (unpublished)
# No standalone survival file exists.  Build the time series
# from individual-crab "Date died" events in the wet-weight file.
# ------------------------------------------------------------
EXP_START_24 <- ymd("2024-08-20")
N_INITIAL_24 <- 15L                       # 15 crabs per treatment

raw_2024 <- read_csv(
  "data/2024-2025/Molting_ Wet weight_and Mortality 2024.csv",
  skip      = 5,
  col_names = c(
    "tub", "treatment", "cell",
    "initial_date",   "initial_mass", "initial_missing",
    "molt1_date",     "molt1_mass",   "molt1_missing",
    "molt2_date",     "molt2_mass",   "molt2_missing",
    "molt3_date",     "molt3_mass",   "molt3_missing",
    "molt4_date",     "molt4_mass",   "molt4_missing",
    "date_died",
    "molt5_date",     "molt5_mass",
    "molt6_date",     "molt6_mass",
    "molt6b_date",    "molt6b_mass"   # apparent typo for 7th molt; kept for fidelity
  ),
  col_types = cols(.default = col_character())
) |>
  filter(!is.na(tub))

# Coerce types and parse treatment.  Dates are kept as Date (not
# POSIXct) so day-arithmetic works cleanly.
parse_date_col <- function(x) {
  as.Date(suppressWarnings(parse_date_time(x, c("ymd HMS", "ymd"))))
}
raw_2024 <- raw_2024 |>
  mutate(
    tub  = as.integer(tub),
    cell = as.integer(cell),
    across(c(ends_with("_date"), date_died), parse_date_col),
    across(ends_with("_mass"), ~ suppressWarnings(as.numeric(.x)))
  ) |>
  bind_cols(parse_treatment_24(raw_2024$treatment))

# Last observed event date defines the experiment end day.
event_dates_24 <- raw_2024 |>
  select(c(ends_with("_date"), date_died)) |>
  as.list() |>
  unlist() |>
  as.Date(origin = "1970-01-01")
EXP_END_24  <- max(event_dates_24, na.rm = TRUE)
LAST_DAY_24 <- as.integer(EXP_END_24 - EXP_START_24)

# Censor the ambient/ambient (tub 7) survival series on the
# flow-failure date.  On 2024-12-16, 14 of 15 A-A crabs died
# simultaneously because the tank lost flow (note recorded in
# row 96, col T of the source xlsx: "Flow cut to tank, all crabs
# died").  Those deaths are an experimental artifact, not a
# treatment effect, so the A-A series is truncated at the day
# before the failure and post-failure deaths are dropped.  The
# one earlier A-A death (cell 26, 2024-10-02) is real and stays.
FLOW_FAIL_AA_DATE <- as.Date("2024-12-16")
FLOW_FAIL_AA_DAY  <- as.integer(FLOW_FAIL_AA_DATE - EXP_START_24)

is_AA <- function(ph, tp) ph == "ambient" & tp == "ambient"

# Deaths per treatment per day, with the A-A flow-failure deaths censored.
deaths_24 <- raw_2024 |>
  filter(!is.na(date_died)) |>
  mutate(day = as.integer(date_died - EXP_START_24)) |>
  filter(!(is_AA(treatment_pH, treatment_temp) & day >= FLOW_FAIL_AA_DAY)) |>
  count(treatment_pH, treatment_temp, day, name = "n_died")

surv_2024 <- raw_2024 |>
  distinct(treatment_pH, treatment_temp) |>
  cross_join(tibble(day = 0:LAST_DAY_24)) |>
  filter(!(is_AA(treatment_pH, treatment_temp) & day >= FLOW_FAIL_AA_DAY)) |>
  left_join(deaths_24, by = c("treatment_pH", "treatment_temp", "day")) |>
  mutate(n_died = replace_na(n_died, 0L)) |>
  group_by(treatment_pH, treatment_temp) |>
  arrange(day, .by_group = TRUE) |>
  mutate(n_alive = N_INITIAL_24 - cumsum(n_died)) |>
  ungroup() |>
  mutate(experiment = "2024-2025", n_initial = N_INITIAL_24) |>
  select(experiment, treatment_pH, treatment_temp, day, n_alive, n_initial)

# ------------------------------------------------------------
# Combined survival data
# ------------------------------------------------------------
survival_combined <- bind_rows(surv_2010, surv_2012, surv_2024) |>
  mutate(prop_alive = n_alive / n_initial) |>
  arrange(experiment, treatment_pH, treatment_temp, day)


# ============================================================
# 2.  WET MASS (growth)
# ============================================================

# ------------------------------------------------------------
# 2a. 2010-2011 (Long et al. 2013)
# Already in long format.  Columns 1-7 hold the data; the rest
# are crab-indicator dummies used in the original R model.
# Note: the "Stage" column labels 1st..5th refer to post-molt
# measurements (RKC molted up to 5 times; no initial mass row).
# ------------------------------------------------------------
stage_to_num <- c("1st" = 1L, "2nd" = 2L, "3rd" = 3L,
                  "4th" = 4L, "5th" = 5L, "6th" = 6L)

wm_2010 <- read_csv(
  "data/2010-2011/Juv wet mass for R 2010-2011.csv",
  show_col_types = FALSE
) |>
  select(
    treatment_pH = Treatment,
    cell         = `Cell #`,
    stage_label  = Stage,
    wet_mass_g   = Wet_Mass,
    exp_day      = ExpDay,
    degree_day   = Day
  ) |>
  mutate(
    treatment_pH   = std_pH(treatment_pH),
    treatment_temp = "ambient",
    molt_num       = unname(stage_to_num[stage_label]),
    experiment     = "2010-2011",
    crab_id        = paste("2010", treatment_pH, sprintf("c%02d", cell), sep = "_"),
    date           = as.Date(NA)
  ) |>
  select(experiment, treatment_pH, treatment_temp,
         crab_id, molt_num, date, exp_day, wet_mass_g)

# ------------------------------------------------------------
# 2b. 2012-2013 (Swiney et al. 2017)
# Wide format with one row per crab.  Pivot to long.  Treatment
# is implicit by tub; assign from the documented design.
# ------------------------------------------------------------
tub_map_2012 <- tibble(
  tub            = 1:6,
  treatment_pH   = c("ambient", "ambient", "ambient", "pH 7.8", "pH 7.8", "pH 7.8"),
  treatment_temp = c("ambient", "+4C",     "+2C",     "ambient", "+2C",    "+4C")
)

raw_2012 <- read_csv(
  "data/2012-2013/RKC Juv OA &Temp Growth and Survival Database 2012-2013__Wet_Weights_dead_&_molt_date.csv",
  skip      = 1,
  col_names = c(
    "tub", "tub2", "cell",
    "initial_date",  "initial_mass", "initial_missing",
    "molt1_date",    "molt1_expday", "wm1_date", "molt1_mass", "molt1_missing",
    "molt2_date",    "molt2_expday", "wm2_date", "molt2_mass", "molt2_missing",
    "molt3_date",    "molt3_expday", "wm3_date", "molt3_mass", "molt3_missing",
    "molt4_date",    "molt4_expday", "wm4_date", "molt4_mass", "molt4_missing",
    "molt5_date",    "molt5_expday", "wm5_date", "molt5_mass", "molt5_missing",
    "death_date",    "death_expday",
    "comments"
  ),
  col_types = cols(.default = col_character())
) |>
  filter(!is.na(tub), !is.na(cell)) |>
  mutate(
    tub  = as.integer(tub),
    cell = as.integer(cell),
    across(ends_with("_date"), parse_date_col),
    across(ends_with("_mass"), ~ suppressWarnings(as.numeric(.x))),
    across(ends_with("_expday"), ~ suppressWarnings(as.integer(.x)))
  ) |>
  left_join(tub_map_2012, by = "tub") |>
  mutate(crab_id = paste("2012", sprintf("t%d", tub),
                         sprintf("c%02d", cell), sep = "_"))

EXP_START_12 <- min(raw_2012$initial_date, na.rm = TRUE)

# Build a tidy long table: one row per crab per measurement.
wm_2012 <- bind_rows(
  raw_2012 |>
    transmute(experiment = "2012-2013", treatment_pH, treatment_temp, crab_id,
              molt_num = 0L,
              date = as_date(initial_date),
              exp_day = as.integer(date - as_date(EXP_START_12)),
              wet_mass_g = initial_mass),
  raw_2012 |>
    transmute(experiment = "2012-2013", treatment_pH, treatment_temp, crab_id,
              molt_num = 1L, date = as_date(wm1_date),
              exp_day = as.integer(date - as_date(EXP_START_12)),
              wet_mass_g = molt1_mass),
  raw_2012 |>
    transmute(experiment = "2012-2013", treatment_pH, treatment_temp, crab_id,
              molt_num = 2L, date = as_date(wm2_date),
              exp_day = as.integer(date - as_date(EXP_START_12)),
              wet_mass_g = molt2_mass),
  raw_2012 |>
    transmute(experiment = "2012-2013", treatment_pH, treatment_temp, crab_id,
              molt_num = 3L, date = as_date(wm3_date),
              exp_day = as.integer(date - as_date(EXP_START_12)),
              wet_mass_g = molt3_mass),
  raw_2012 |>
    transmute(experiment = "2012-2013", treatment_pH, treatment_temp, crab_id,
              molt_num = 4L, date = as_date(wm4_date),
              exp_day = as.integer(date - as_date(EXP_START_12)),
              wet_mass_g = molt4_mass),
  raw_2012 |>
    transmute(experiment = "2012-2013", treatment_pH, treatment_temp, crab_id,
              molt_num = 5L, date = as_date(wm5_date),
              exp_day = as.integer(date - as_date(EXP_START_12)),
              wet_mass_g = molt5_mass)
) |>
  filter(!is.na(wet_mass_g))

# ------------------------------------------------------------
# 2c. 2024-2025 (unpublished)
# Wide format with initial wet mass + post-molt masses 1-6.
# raw_2024 was already read above for the survival derivation.
# ------------------------------------------------------------
wm_2024 <- bind_rows(
  raw_2024 |>
    transmute(experiment = "2024-2025", treatment_pH, treatment_temp,
              crab_id = paste("2024", sprintf("t%d", tub),
                              sprintf("c%02d", cell), sep = "_"),
              molt_num = 0L,
              date = as_date(initial_date),
              wet_mass_g = initial_mass),
  raw_2024 |>
    transmute(experiment = "2024-2025", treatment_pH, treatment_temp,
              crab_id = paste("2024", sprintf("t%d", tub),
                              sprintf("c%02d", cell), sep = "_"),
              molt_num = 1L,
              date = as_date(molt1_date),
              wet_mass_g = molt1_mass),
  raw_2024 |>
    transmute(experiment = "2024-2025", treatment_pH, treatment_temp,
              crab_id = paste("2024", sprintf("t%d", tub),
                              sprintf("c%02d", cell), sep = "_"),
              molt_num = 2L,
              date = as_date(molt2_date),
              wet_mass_g = molt2_mass),
  raw_2024 |>
    transmute(experiment = "2024-2025", treatment_pH, treatment_temp,
              crab_id = paste("2024", sprintf("t%d", tub),
                              sprintf("c%02d", cell), sep = "_"),
              molt_num = 3L,
              date = as_date(molt3_date),
              wet_mass_g = molt3_mass),
  raw_2024 |>
    transmute(experiment = "2024-2025", treatment_pH, treatment_temp,
              crab_id = paste("2024", sprintf("t%d", tub),
                              sprintf("c%02d", cell), sep = "_"),
              molt_num = 4L,
              date = as_date(molt4_date),
              wet_mass_g = molt4_mass),
  raw_2024 |>
    transmute(experiment = "2024-2025", treatment_pH, treatment_temp,
              crab_id = paste("2024", sprintf("t%d", tub),
                              sprintf("c%02d", cell), sep = "_"),
              molt_num = 5L,
              date = as_date(molt5_date),
              wet_mass_g = molt5_mass),
  raw_2024 |>
    transmute(experiment = "2024-2025", treatment_pH, treatment_temp,
              crab_id = paste("2024", sprintf("t%d", tub),
                              sprintf("c%02d", cell), sep = "_"),
              molt_num = 6L,
              date = as_date(molt6_date),
              wet_mass_g = molt6_mass)
) |>
  filter(!is.na(wet_mass_g)) |>
  mutate(exp_day = as.integer(date - EXP_START_24)) |>
  select(experiment, treatment_pH, treatment_temp, crab_id,
         molt_num, date, exp_day, wet_mass_g)

# ------------------------------------------------------------
# Combined wet mass data
# ------------------------------------------------------------
wet_mass_combined <- bind_rows(wm_2010, wm_2012, wm_2024) |>
  arrange(experiment, treatment_pH, treatment_temp, crab_id, molt_num)


# ============================================================
# 3.  Write outputs and report
# ============================================================
write_csv(survival_combined, "data/combined/survival_combined.csv")
write_csv(wet_mass_combined, "data/combined/wet_mass_combined.csv")

message("\n--- Survival ---")
print(
  survival_combined |>
    group_by(experiment, treatment_pH, treatment_temp) |>
    summarise(n_days = n(), final_alive = last(n_alive), .groups = "drop")
)

message("\n--- Wet mass ---")
print(
  wet_mass_combined |>
    group_by(experiment, treatment_pH, treatment_temp) |>
    summarise(n_measurements = n(),
              n_crabs        = n_distinct(crab_id),
              .groups        = "drop")
)
