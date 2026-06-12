# ============================================================
# check_against_papers.R
#
# Re-fit the survival and (where available) wet-mass models from
# Long et al. 2013 and Swiney et al. 2017 using the cleaned data
# in data/combined/, and print side-by-side comparisons against
# the values reported in the published papers.
# ============================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(stringr)
  library(lme4)
})

survival  <- read_csv("data/combined/survival_combined.csv",  show_col_types = FALSE)
wet_mass  <- read_csv("data/combined/wet_mass_combined.csv",  show_col_types = FALSE)

# ------------------------------------------------------------
# Helper: fit per-treatment constant mortality rate using the
# same binomial likelihood Long et al. (2013) used:
#   pAlive(t) = exp(-r * t)
#   N_alive ~ Binomial(N_initial, pAlive(t))
# Returns rate (per day) and an asymptotic SE from the Hessian.
# ------------------------------------------------------------
fit_mortality <- function(d) {
  nll <- function(log_r) {
    r <- exp(log_r)
    p <- exp(-r * d$day)
    p <- pmin(pmax(p, 1e-12), 1 - 1e-12)
    -sum(d$n_alive * log(p) + (d$n_initial - d$n_alive) * log(1 - p))
  }
  fit <- optim(par = log(0.005), fn = nll, method = "Brent",
               lower = log(1e-6), upper = log(1), hessian = TRUE)
  r  <- exp(fit$par)
  # delta-method SE on r from the log-r Hessian
  se <- if (fit$hessian > 0) sqrt(1 / fit$hessian) * r else NA_real_
  tibble(rate = r, se = se)
}

# ============================================================
# 1. SURVIVAL — 2010-2011 (Long et al. 2013, RKC)
# ============================================================
cat("\n============================================================\n")
cat("LONG ET AL. 2013 — survival (RKC)\n")
cat("Reported: r_control = 0.0023 +/- 0.00007 day^-1\n")
cat("          r_pH7.8   = 0.0047 +/- 0.00011\n")
cat("          r_pH7.5   = 0.025  +/- 0.00066\n")
cat("Reported relative effects: pH 7.8 +104% over control,\n")
cat("                           pH 7.5 +997% over control\n")
cat("============================================================\n")

surv_long <- survival |>
  filter(experiment == "2010-2011") |>
  group_by(treatment_pH) |>
  group_modify(~ fit_mortality(.x)) |>
  ungroup() |>
  mutate(rate_round   = signif(rate, 3),
         se_round     = signif(se,   3))

# Add % change vs control
control_r <- surv_long$rate[surv_long$treatment_pH == "ambient"]
surv_long <- surv_long |>
  mutate(pct_vs_control = round(100 * (rate / control_r - 1)))

print(surv_long)


# ============================================================
# 2. SURVIVAL — 2012-2013 (Swiney et al. 2017, RKC)
# ============================================================
cat("\n============================================================\n")
cat("SWINEY ET AL. 2017 — survival (RKC)\n")
cat("Reported relative effects: pH 7.8 vs ambient: +82%\n")
cat("                           temp +2C / +4C    : +49% to +107%\n")
cat("Reported survival ranking (lowest -> highest):\n")
cat("  pH 7.8/+4C  <  amb/+2C  <  pH 7.8/amb  <  amb/+4C  <  pH 7.8/+2C  <  amb/amb\n")
cat("Reported final survival: 3%% at pH 7.8/+4C\n")
cat("============================================================\n")

surv_swiney <- survival |>
  filter(experiment == "2012-2013") |>
  group_by(treatment_pH, treatment_temp) |>
  group_modify(~ fit_mortality(.x)) |>
  ungroup() |>
  mutate(rate_round = signif(rate, 3),
         se_round   = signif(se,   3))

# Control rate for relative-effect calculations
control_r12 <- surv_swiney$rate[surv_swiney$treatment_pH == "ambient" &
                                surv_swiney$treatment_temp == "ambient"]
surv_swiney <- surv_swiney |>
  mutate(pct_vs_control = round(100 * (rate / control_r12 - 1)))
print(surv_swiney, n = Inf)

# Marginal effects: pH only (at ambient temp) and temp only (at ambient pH)
pH_only_effect <- surv_swiney$rate[surv_swiney$treatment_pH == "pH 7.8" &
                                   surv_swiney$treatment_temp == "ambient"] / control_r12 - 1
plus2_only_effect <- surv_swiney$rate[surv_swiney$treatment_pH == "ambient" &
                                      surv_swiney$treatment_temp == "+2C"] / control_r12 - 1
plus4_only_effect <- surv_swiney$rate[surv_swiney$treatment_pH == "ambient" &
                                      surv_swiney$treatment_temp == "+4C"] / control_r12 - 1
cat(sprintf("\nMarginal effect of pH 7.8 at ambient temp : %+d%% (paper: +82%%)\n",
            round(100 * pH_only_effect)))
cat(sprintf("Marginal effect of +2C at ambient pH      : %+d%% (paper range: +49 to +107%%)\n",
            round(100 * plus2_only_effect)))
cat(sprintf("Marginal effect of +4C at ambient pH      : %+d%% (paper range: +49 to +107%%)\n",
            round(100 * plus4_only_effect)))

# Final survival fraction in pH 7.8/+4C
final_78_4 <- survival |>
  filter(experiment == "2012-2013",
         treatment_pH == "pH 7.8", treatment_temp == "+4C") |>
  slice_tail(n = 1) |>
  mutate(pct = round(100 * prop_alive, 1))
cat(sprintf("\nFinal survival pH 7.8/+4C (cleaned data): %.1f%% (paper: 3%%)\n",
            final_78_4$pct))

# Survival ranking from cleaned data
ranking <- survival |>
  filter(experiment == "2012-2013") |>
  group_by(treatment_pH, treatment_temp) |>
  summarise(final = last(prop_alive), .groups = "drop") |>
  arrange(final) |>
  mutate(label = paste0(treatment_pH, "/", treatment_temp,
                        " (", round(100 * final, 1), "%)"))
cat("\nSurvival ranking (cleaned data, lowest -> highest):\n  ",
    paste(ranking$label, collapse = "\n   "), "\n", sep = "")


# ============================================================
# 3. WET MASS — 2010-2011 (Long et al. 2013, RKC)
# ============================================================
cat("\n============================================================\n")
cat("LONG ET AL. 2013 — wet mass growth (RKC)\n")
cat("Reported model: WM = a * exp(b * t), t in degree-days\n")
cat("  Control: a = 0.00667, b = 0.000829\n")
cat("  pH 7.8 : a = 0.00667, b = 0.000557\n")
cat("Reported endpoint: control mass 61%% higher than pH 7.8 by end of expt.\n")
cat("============================================================\n")

# We need degree-days, which live in the original 2010 wet mass
# file as the "Day" column.  Re-read just that column.
#
# Per Long et al. 2013 methods: "the initial size was not included
# in analysis" — i.e. the "1st" stage rows are dropped.  Best model
# (Table 5): shared intercept (a), treatment-specific slope (b),
# crab as a within-treatment intercept factor.  Reproduced here as
# a linear mixed model with a random intercept on cell.
wm10_raw <- read_csv(
  "data/2010-2011/Juv wet mass for R 2010-2011.csv",
  show_col_types = FALSE
) |>
  select(Treatment, `Cell #`, Stage, Wet_Mass, ExpDay, Day) |>
  rename(treatment = Treatment, cell = `Cell #`, stage = Stage,
         wet_mass = Wet_Mass, exp_day = ExpDay, degree_day = Day) |>
  mutate(treatment = if_else(treatment == "Control", "ambient", treatment),
         cell = paste(treatment, cell, sep = "_"))

wm10 <- wm10_raw |> filter(stage != "1st")

m_growth <- lmer(log(wet_mass) ~ degree_day:treatment + (1 | cell), data = wm10)
fe <- fixef(m_growth)
a_shared <- exp(unname(fe[1]))
b_amb    <- unname(fe["degree_day:treatmentambient"])
b_78     <- unname(fe["degree_day:treatmentpH7.8"])

growth_long <- tibble(
  treatment = c("ambient", "pH7.8"),
  a         = c(a_shared,  a_shared),
  b         = c(b_amb,     b_78),
  n_obs     = c(sum(wm10$treatment == "ambient"),
                sum(wm10$treatment == "pH7.8"))
) |>
  mutate(a = signif(a, 3),
         b = signif(b, 3))

print(growth_long)

# End-of-experiment mass ratio: the paper claims control / pH 7.8 = 1.61
# (i.e. 61% higher).  Compute it from the fits at the max observed dd.
max_dd <- max(wm10$degree_day, na.rm = TRUE)
ratio  <- exp((b_amb - b_78) * max_dd)
cat(sprintf("\nMax observed degree-day: %.0f\n", max_dd))
cat(sprintf("End-of-expt mass ratio control/pH7.8 (cleaned data): %.2fx (paper: 1.61x)\n",
            ratio))


# ============================================================
# 4. WET MASS — 2012-2013
# ============================================================
cat("\n============================================================\n")
cat("SWINEY ET AL. 2017 — wet mass\n")
cat("Not reported in the paper (only carapace length was analysed).\n")
cat("Skipping comparison; wet-mass data has been combined for the\n")
cat("meta-analysis but cannot be cross-checked against the paper.\n")
cat("============================================================\n")
