# ============================================================
# growth.R
#
# Bayesian growth analysis of juvenile red king crab wet mass
# in response to ocean acidification and warming.
#
# Model (log-linear on wet mass, with treatment-specific
# growth rate per day):
#
#   log(WM_{c,t}) = beta_0 + beta_exp * exp_c
#                 + beta_pH * pH_c + beta_T * temp_c + ...
#                 + (delta_0 + delta_exp * exp_c
#                   + delta_pH * pH_c + delta_T * temp_c
#                   + delta_int * pH_c * temp_c) * day_{c,t}
#                 + a_crab + u_tank
#
# Where the betas adjust the intercept (initial mass) per
# experiment / treatment, and the deltas adjust the growth
# rate (slope on day) per experiment / treatment.
#
# Random effects:
#   a_crab ~ Normal(0, sigma_crab)    (individual size variation)
#   u_tank ~ Normal(0, sigma_tank)    (tank-level intercept)
#
# Uses experimental DAYS (not degree days) so temperature
# can be identified as a free covariate.
#
# Two model versions, mirroring survival.R:
#   Model A: 2010 + 2012 only (published experiments)
#   Model B: + 2024-25 (all three experiments)
# ============================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(stringr)
  library(brms)
  library(tidybayes)
  library(ggplot2)
  library(posterior)
})

options(mc.cores = 4)

# ------------------------------------------------------------
# 1. Load and prepare data
# ------------------------------------------------------------
wet_mass <- read_csv("data/combined/wet_mass_combined.csv",
                     show_col_types = FALSE)

# Two 2012 measurements at exp_day 505 and 508 are clearly
# date-entry errors (the experiment ran 184 days).  Drop them.
wet_mass <- wet_mass |> filter(exp_day <= 250 | is.na(exp_day))

PH_CENTER   <- 8.0
TEMP_CENTER <- 10.0

mk_growth_data <- function(df, experiments_in) {
  df |>
    filter(experiment %in% experiments_in,
           !is.na(wet_mass_g), !is.na(exp_day),
           wet_mass_g > 0) |>
    mutate(
      log_wm     = log(wet_mass_g),
      pH_c       = mean_pH      - PH_CENTER,
      temp_c     = mean_temp_C  - TEMP_CENTER,
      tank       = paste(experiment, treatment_pH, treatment_temp, sep = " | "),
      experiment = factor(experiment,
                          levels = c("2010-2011", "2012-2013", "2024-2025"))
    ) |>
    droplevels()
}

mod_data     <- mk_growth_data(wet_mass, c("2010-2011", "2012-2013"))
mod_data_all3 <- mk_growth_data(wet_mass, c("2010-2011", "2012-2013", "2024-2025"))

cat("--- growth model data summary ---\n")
cat("Model A: n_obs =", nrow(mod_data),
    "  n_crabs =", n_distinct(mod_data$crab_id),
    "  n_tanks =", n_distinct(mod_data$tank), "\n")
cat("Model B: n_obs =", nrow(mod_data_all3),
    "  n_crabs =", n_distinct(mod_data_all3$crab_id),
    "  n_tanks =", n_distinct(mod_data_all3$tank), "\n")

print(mod_data_all3 |>
        distinct(experiment, treatment_pH, treatment_temp,
                 mean_pH, mean_temp_C, pH_c, temp_c, tank),
      n = Inf)

# ------------------------------------------------------------
# 2. Priors
# ------------------------------------------------------------
# log(initial wet mass) ~ -5 (mean initial ~0.01 g).
# Growth-rate slopes (per day, log scale) are small; weakly
# informative prior Normal(0, 1) is appropriate.
priors_growth <- c(
  prior(normal(-5, 1), class = "Intercept"),
  prior(normal(0, 1),  class = "b"),
  prior(exponential(2), class = "sd")   # SDs on log mass scale
)

# ------------------------------------------------------------
# 3. Fit Model A (published only)
# ------------------------------------------------------------
fit_path_A <- "output/models/growth_fit.rds"
if (file.exists(fit_path_A)) {
  cat("\nLoading cached growth Model A from", fit_path_A, "\n")
  fit_A <- readRDS(fit_path_A)
} else {
  cat("\nFitting growth Model A...\n")
  fit_A <- brm(
    formula = log_wm ~ exp_day * (experiment + pH_c * temp_c) +
                       (1 | crab_id) + (1 | tank),
    data    = mod_data,
    family  = gaussian(),
    prior   = priors_growth,
    chains  = 4, iter = 3000, warmup = 1500,
    seed    = 20260612,
    control = list(adapt_delta = 0.95, max_treedepth = 12),
    refresh = 0,
    backend = "rstan"
  )
  saveRDS(fit_A, fit_path_A)
}

# ------------------------------------------------------------
# 4. Fit Model B (all three experiments)
# ------------------------------------------------------------
fit_path_B <- "output/models/growth_fit_all3.rds"
if (file.exists(fit_path_B)) {
  cat("\nLoading cached growth Model B from", fit_path_B, "\n")
  fit_B <- readRDS(fit_path_B)
} else {
  cat("\nFitting growth Model B...\n")
  fit_B <- brm(
    formula = log_wm ~ exp_day * (experiment + pH_c * temp_c) +
                       (1 | crab_id) + (1 | tank),
    data    = mod_data_all3,
    family  = gaussian(),
    prior   = priors_growth,
    chains  = 4, iter = 3000, warmup = 1500,
    seed    = 20260612,
    control = list(adapt_delta = 0.95, max_treedepth = 12),
    refresh = 0,
    backend = "rstan"
  )
  saveRDS(fit_B, fit_path_B)
}

# ------------------------------------------------------------
# 5. Summaries
# ------------------------------------------------------------
cat("\n--- Growth Model A summary ---\n")
print(summary(fit_A))
cat("\nmax Rhat:", round(max(rhat(fit_A), na.rm=TRUE), 3), "\n")

cat("\n--- Growth Model B summary ---\n")
print(summary(fit_B))
cat("\nmax Rhat:", round(max(rhat(fit_B), na.rm=TRUE), 3), "\n")

# ------------------------------------------------------------
# 6. Per-tank posterior growth rates (slope on day)
# ------------------------------------------------------------
# The instantaneous growth rate (per day, on log mass) for
# tank i is:
#   delta_i = d_log_wm/d_day = baseline_slope
#             + delta_exp * exp_i + delta_pH * pH_c
#             + delta_T * temp_c + delta_int * pH_c * temp_c
# Compute from posterior by predicting at two day values and
# differencing.

tank_growth_rates <- function(fit, data) {
  newd <- data |>
    distinct(tank, experiment, treatment_pH, treatment_temp,
             mean_pH, mean_temp_C, pH_c, temp_c)
  # Use one real crab_id from the data as a placeholder; we
  # drop the crab RE via re_formula and use allow_new_levels
  # for the tank in case any tank gets re-rolled by the join.
  placeholder_crab <- data$crab_id[1]
  newd2 <- bind_rows(
    mutate(newd, exp_day = 0,   crab_id = placeholder_crab),
    mutate(newd, exp_day = 100, crab_id = placeholder_crab)
  )
  preds <- newd2 |>
    add_epred_draws(fit, re_formula = NA,
                    allow_new_levels = TRUE) |>
    ungroup() |>
    select(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C, exp_day, .draw, .epred) |>
    pivot_wider(names_from = exp_day, values_from = .epred,
                names_prefix = "d") |>
    mutate(rate = (d100 - d0) / 100)               # log-mass per day
  preds |>
    group_by(tank, experiment, treatment_pH, treatment_temp,
             mean_pH, mean_temp_C) |>
    median_qi(rate, .width = 0.95) |>
    ungroup() |>
    arrange(rate)
}

cat("\n--- Posterior per-tank growth rates (log-mass per day), Model A ---\n")
tank_rates_A <- tank_growth_rates(fit_A, mod_data)
print(tank_rates_A, n = Inf)

cat("\n--- Posterior per-tank growth rates, Model B ---\n")
tank_rates_B <- tank_growth_rates(fit_B, mod_data_all3)
print(tank_rates_B, n = Inf)

# ------------------------------------------------------------
# 7. Plots
# ------------------------------------------------------------
theme_set(theme_bw(base_size = 11))

# 7a. Coefficient plot — focus on the day-interaction terms,
# which are the growth-rate effects.

extract_rate_coefs <- function(fit, model_label, all3 = FALSE) {
  draws <- as_draws_df(fit) |> as_tibble()
  cols <- c("b_exp_day",
            "b_exp_day:experiment2012M2013",
            if (all3) "b_exp_day:experiment2024M2025",
            "b_exp_day:pH_c",
            "b_exp_day:temp_c",
            "b_exp_day:pH_c:temp_c",
            "sd_crab_id__Intercept",
            "sd_tank__Intercept")
  cols <- intersect(cols, names(draws))
  draws |> select(all_of(cols)) |>
    pivot_longer(everything(), names_to = "parameter", values_to = "value") |>
    mutate(model = model_label)
}

coefs_A <- extract_rate_coefs(fit_A, "Model A (published only)",      all3 = FALSE)
coefs_B <- extract_rate_coefs(fit_B, "Model B (all 3 experiments)",   all3 = TRUE)

label_param <- function(x) {
  recode(x,
    "b_exp_day"                       = "day (baseline log-mass growth/day)",
    "b_exp_day:experiment2012M2013"   = "day x experiment 2012 vs 2010",
    "b_exp_day:experiment2024M2025"   = "day x experiment 2024 vs 2010",
    "b_exp_day:pH_c"                  = "day x pH",
    "b_exp_day:temp_c"                = "day x temp",
    "b_exp_day:pH_c:temp_c"           = "day x pH x temp interaction",
    "sd_crab_id__Intercept"           = "Crab-level SD (initial size)",
    "sd_tank__Intercept"              = "Tank-level SD")
}

coefs_both <- bind_rows(coefs_A, coefs_B) |>
  mutate(parameter = label_param(parameter))

p_coef <- ggplot(coefs_both, aes(x = value, y = parameter, fill = model)) +
  stat_halfeye(.width = c(0.66, 0.95), alpha = 0.6,
               position = position_dodge(width = 0.5)) +
  geom_vline(xintercept = 0, linetype = "dashed", colour = "grey50") +
  scale_fill_manual(values = c("Model A (published only)" = "steelblue",
                               "Model B (all 3 experiments)" = "darkorange")) +
  labs(x = "Posterior value (log mass per day, or log mass SD)",
       y = NULL, fill = NULL,
       title = "Growth rate (day) coefficients: Model A vs Model B",
       subtitle = "Day-interaction terms capture how covariates modulate growth rate per day.") +
  theme(legend.position = "bottom")
ggsave("output/figures/growth_coefficients.png", p_coef,
       width = 9, height = 5.5, dpi = 150)

# 7b. Observed vs fitted per tank (Model B)
pred_grid_B <- mod_data_all3 |>
  distinct(tank, experiment, treatment_pH, treatment_temp,
           pH_c, temp_c, mean_pH, mean_temp_C) |>
  tidyr::crossing(exp_day = seq(0, max(mod_data_all3$exp_day, na.rm=TRUE), by = 5)) |>
  mutate(crab_id = "_pop_level_")

pred_grid_B <- pred_grid_B |> mutate(crab_id = mod_data_all3$crab_id[1])
pred_B <- pred_grid_B |>
  add_epred_draws(fit_B, ndraws = 400, re_formula = NA,
                  allow_new_levels = TRUE) |>
  group_by(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C, exp_day) |>
  median_qi(.epred, .width = 0.95) |>
  rename(log_wm_pred = .epred,
         log_wm_lo  = .lower,
         log_wm_hi  = .upper)

p_curves_B <- ggplot() +
  geom_ribbon(data = pred_B,
              aes(x = exp_day, ymin = exp(log_wm_lo), ymax = exp(log_wm_hi)),
              alpha = 0.22, fill = "darkorange") +
  geom_line(data = pred_B,
            aes(x = exp_day, y = exp(log_wm_pred)),
            colour = "darkorange", linewidth = 0.7) +
  geom_point(data = mod_data_all3,
             aes(x = exp_day, y = wet_mass_g),
             size = 0.3, alpha = 0.35) +
  facet_wrap(~ tank, ncol = 4, scales = "free_y") +
  scale_y_log10() +
  labs(x = "Experimental day",
       y = "Wet mass (g, log scale)",
       title = "Growth Model B: observed wet mass vs fitted growth curve per tank",
       subtitle = "Line: population-level posterior median.  Ribbon: 95% credible interval (random effects dropped).")
ggsave("output/figures/growth_observed_vs_predicted_all3.png", p_curves_B,
       width = 12, height = 9, dpi = 150)

# Same for Model A
pred_grid_A <- mod_data |>
  distinct(tank, experiment, treatment_pH, treatment_temp,
           pH_c, temp_c, mean_pH, mean_temp_C) |>
  tidyr::crossing(exp_day = seq(0, max(mod_data$exp_day, na.rm=TRUE), by = 5)) |>
  mutate(crab_id = "_pop_level_")

pred_grid_A <- pred_grid_A |> mutate(crab_id = mod_data$crab_id[1])
pred_A <- pred_grid_A |>
  add_epred_draws(fit_A, ndraws = 400, re_formula = NA,
                  allow_new_levels = TRUE) |>
  group_by(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C, exp_day) |>
  median_qi(.epred, .width = 0.95) |>
  rename(log_wm_pred = .epred,
         log_wm_lo  = .lower,
         log_wm_hi  = .upper)

p_curves_A <- ggplot() +
  geom_ribbon(data = pred_A,
              aes(x = exp_day, ymin = exp(log_wm_lo), ymax = exp(log_wm_hi)),
              alpha = 0.22, fill = "steelblue") +
  geom_line(data = pred_A,
            aes(x = exp_day, y = exp(log_wm_pred)),
            colour = "steelblue", linewidth = 0.7) +
  geom_point(data = mod_data,
             aes(x = exp_day, y = wet_mass_g),
             size = 0.3, alpha = 0.35) +
  facet_wrap(~ tank, ncol = 3, scales = "free_y") +
  scale_y_log10() +
  labs(x = "Experimental day",
       y = "Wet mass (g, log scale)",
       title = "Growth Model A: observed wet mass vs fitted growth curve per tank",
       subtitle = "Line: population-level posterior median.  Ribbon: 95% credible interval (random effects dropped).")
ggsave("output/figures/growth_observed_vs_predicted.png", p_curves_A,
       width = 10, height = 6.5, dpi = 150)

# 7c. Growth-rate surface over the pH x temp space (Model B)
surface_grid <- crossing(
  mean_pH     = seq(7.45, 8.10, length.out = 40),
  mean_temp_C = seq(7.0,  13,   length.out = 40)
) |>
  mutate(pH_c   = mean_pH    - PH_CENTER,
         temp_c = mean_temp_C - TEMP_CENTER,
         experiment = "2024-2025",
         crab_id    = mod_data_all3$crab_id[1])

# Compute growth rate as predicted log-WM at exp_day=100 minus exp_day=0, /100
surf_two <- bind_rows(mutate(surface_grid, exp_day = 0),
                      mutate(surface_grid, exp_day = 100)) |>
  add_epred_draws(fit_B, ndraws = 200, re_formula = NA,
                  allow_new_levels = TRUE) |>
  ungroup() |>
  select(mean_pH, mean_temp_C, exp_day, .draw, .epred) |>
  pivot_wider(names_from = exp_day, values_from = .epred,
              names_prefix = "d") |>
  mutate(growth_rate = (d100 - d0) / 100) |>
  group_by(mean_pH, mean_temp_C) |>
  summarise(rate_med = median(growth_rate), .groups = "drop")

obs_tanks <- mod_data_all3 |>
  distinct(experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C)

p_surface <- ggplot(surf_two, aes(x = mean_pH, y = mean_temp_C,
                                  fill = rate_med)) +
  geom_raster(interpolate = TRUE) +
  geom_contour(aes(z = rate_med), colour = "white", alpha = 0.4) +
  geom_point(data = obs_tanks,
             aes(fill = NULL, shape = experiment),
             colour = "black", fill = "white", size = 2.4) +
  scale_fill_viridis_c(option = "viridis", direction = 1,
                       name = "log-mass\ngrowth\nrate per day") +
  scale_shape_manual(values = c("2010-2011" = 21, "2012-2013" = 22,
                                "2024-2025" = 24),
                     name = "Experiment") +
  labs(x = "Mean pH",
       y = "Mean temperature (C)",
       title = "Posterior median log-mass growth rate, Model B",
       subtitle = "Population-level surface (random effects dropped); observed treatments overlaid")
ggsave("output/figures/growth_rate_surface_all3.png", p_surface,
       width = 8, height = 5, dpi = 150)

# Save the per-tank rate tables for the writeup
write_csv(tank_rates_A, "output/growth_tank_rates_A.csv")
write_csv(tank_rates_B, "output/growth_tank_rates_B.csv")

cat("\nGrowth figures written:\n")
cat("  - growth_coefficients.png\n")
cat("  - growth_observed_vs_predicted.png\n")
cat("  - growth_observed_vs_predicted_all3.png\n")
cat("  - growth_rate_surface_all3.png\n")


# ============================================================
# ============================================================
# EXTENSION: tank-level initial mass as a covariate.
# ------------------------------------------------------------
# Does mean initial wet mass explain the experiment-level
# differences in growth rate?  Parallel test to the survival
# initial-mass analysis (survival.R section 4).  Adds the
# centered log tank-mean initial mass as both an intercept
# adjustment and a day-interaction, then compares to the
# base growth fits via LOO and a coefficient table.
# ============================================================
# ============================================================

# Tank-level mean initial mass (re-derived here to keep growth.R
# self-contained).
tank_mass <- wet_mass |>
  filter(molt_num == 0) |>
  group_by(experiment, treatment_pH, treatment_temp) |>
  summarise(mean_initial_mass_g = mean(wet_mass_g, na.rm = TRUE),
            n_initial_obs       = n(),
            .groups = "drop")

# 2010 pH 7.5 has no initial-mass measurements; impute as the
# mean of the other two 2010 tanks (same Bristol Bay cohort).
imp_2010 <- mean(tank_mass$mean_initial_mass_g[tank_mass$experiment == "2010-2011"])
tank_mass <- tank_mass |>
  bind_rows(tibble(experiment = "2010-2011",
                   treatment_pH = "pH 7.5",
                   treatment_temp = "ambient",
                   mean_initial_mass_g = imp_2010,
                   n_initial_obs = 0L))

LOG_MASS_CENTER <- mean(log(tank_mass$mean_initial_mass_g[tank_mass$n_initial_obs > 0]))
tank_mass <- tank_mass |>
  mutate(log_mass_c = log(mean_initial_mass_g) - LOG_MASS_CENTER) |>
  select(experiment, treatment_pH, treatment_temp, log_mass_c)

mod_data_mass     <- mod_data |>
  left_join(tank_mass |>
              mutate(experiment = factor(experiment,
                                         levels = levels(mod_data$experiment))),
            by = c("experiment", "treatment_pH", "treatment_temp"))

mod_data_mass_all3 <- mod_data_all3 |>
  left_join(tank_mass |>
              mutate(experiment = factor(experiment,
                                         levels = levels(mod_data_all3$experiment))),
            by = c("experiment", "treatment_pH", "treatment_temp"))

stopifnot(all(!is.na(mod_data_mass$log_mass_c)),
          all(!is.na(mod_data_mass_all3$log_mass_c)))

fit_path_A_mass <- "output/models/growth_fit_mass.rds"
if (file.exists(fit_path_A_mass)) {
  cat("\nLoading cached growth+mass Model A from", fit_path_A_mass, "\n")
  fit_A_mass <- readRDS(fit_path_A_mass)
} else {
  cat("\nFitting growth Model A with mass covariate...\n")
  fit_A_mass <- brm(
    formula = log_wm ~ exp_day * (experiment + pH_c * temp_c + log_mass_c) +
                       (1 | crab_id) + (1 | tank),
    data    = mod_data_mass,
    family  = gaussian(),
    prior   = priors_growth,
    chains  = 4, iter = 3000, warmup = 1500,
    seed    = 20260612,
    control = list(adapt_delta = 0.95, max_treedepth = 12),
    refresh = 0,
    backend = "rstan"
  )
  saveRDS(fit_A_mass, fit_path_A_mass)
}

fit_path_B_mass <- "output/models/growth_fit_mass_all3.rds"
if (file.exists(fit_path_B_mass)) {
  cat("\nLoading cached growth+mass Model B from", fit_path_B_mass, "\n")
  fit_B_mass <- readRDS(fit_path_B_mass)
} else {
  cat("\nFitting growth Model B with mass covariate...\n")
  fit_B_mass <- brm(
    formula = log_wm ~ exp_day * (experiment + pH_c * temp_c + log_mass_c) +
                       (1 | crab_id) + (1 | tank),
    data    = mod_data_mass_all3,
    family  = gaussian(),
    prior   = priors_growth,
    chains  = 4, iter = 3000, warmup = 1500,
    seed    = 20260612,
    control = list(adapt_delta = 0.95, max_treedepth = 12),
    refresh = 0,
    backend = "rstan"
  )
  saveRDS(fit_B_mass, fit_path_B_mass)
}

cat("\n--- Growth+mass Model A summary ---\n")
print(summary(fit_A_mass))
cat("\n--- Growth+mass Model B summary ---\n")
print(summary(fit_B_mass))

# LOO comparisons
fit_A      <- add_criterion(fit_A,      "loo")
fit_A_mass <- add_criterion(fit_A_mass, "loo")
fit_B      <- add_criterion(fit_B,      "loo")
fit_B_mass <- add_criterion(fit_B_mass, "loo")

cat("\n== Growth Model A: no mass vs +mass ==\n")
print(loo_compare(fit_A, fit_A_mass))
cat("\n== Growth Model B: no mass vs +mass ==\n")
print(loo_compare(fit_B, fit_B_mass))

# Compare day-interaction coefficients to see if experiment
# effects shrink when mass is added.
extract_rate_summary <- function(fit, model_label, all3 = FALSE) {
  d <- as_draws_df(fit) |> as_tibble()
  rate_cols <- intersect(c("b_exp_day",
                            "b_exp_day:experiment2012M2013",
                            if (all3) "b_exp_day:experiment2024M2025",
                            "b_exp_day:pH_c",
                            "b_exp_day:temp_c",
                            "b_exp_day:pH_c:temp_c",
                            "b_exp_day:log_mass_c"),
                          names(d))
  tibble(model     = model_label,
         parameter = rate_cols,
         median = sapply(d[rate_cols], median),
         lower  = sapply(d[rate_cols], quantile, 0.025),
         upper  = sapply(d[rate_cols], quantile, 0.975))
}

cat("\n--- Growth-rate coefficients: no-mass vs +mass ---\n")
print(bind_rows(
  extract_rate_summary(fit_A,       "Model A (no mass)"),
  extract_rate_summary(fit_A_mass,  "Model A (+mass)"),
  extract_rate_summary(fit_B,       "Model B (no mass)",       all3 = TRUE),
  extract_rate_summary(fit_B_mass,  "Model B (+mass)",         all3 = TRUE)
) |> mutate(across(c(median, lower, upper),
                   \(x) ifelse(abs(x) < 0.01, formatC(x, format = "e", digits = 2),
                               formatC(x, digits = 3)))), n = Inf)

saveRDS(fit_A,      "output/models/growth_fit.rds")
saveRDS(fit_A_mass, "output/models/growth_fit_mass.rds")
saveRDS(fit_B,      "output/models/growth_fit_all3.rds")
saveRDS(fit_B_mass, "output/models/growth_fit_mass_all3.rds")

cat("\nDone.\n")


# ============================================================
# ============================================================
# EXTENSION: smooth pH (threshold test).
# ------------------------------------------------------------
# Replaces the linear pH * temp terms with a thin-plate smooth
# over mean_pH for both the intercept (initial mass) and the
# growth-rate slope, while keeping temperature linear.
#
# The growth-rate-vs-pH smooth uses `s(mean_pH, by = exp_day)`:
# in mgcv / brms this multiplies the smooth by exp_day, so the
# smooth's shape over pH represents how the growth rate per day
# varies with pH.
# ============================================================
# ============================================================

priors_sPH_growth <- c(
  prior(normal(-5, 1), class = "Intercept"),
  prior(normal(0, 1),  class = "b"),
  prior(exponential(2), class = "sd"),
  prior(student_t(3, 0, 1), class = "sds")
)

# ------------------------------------------------------------
# Model A_sPH
# ------------------------------------------------------------
fit_path_A_sPH <- "output/models/growth_fit_sPH.rds"
if (file.exists(fit_path_A_sPH)) {
  cat("\nLoading cached growth smooth-pH (A) from", fit_path_A_sPH, "\n")
  fit_A_sPH <- readRDS(fit_path_A_sPH)
} else {
  cat("\nFitting growth smooth-pH Model A...\n")
  fit_A_sPH <- brm(
    formula = log_wm ~ exp_day * (experiment + temp_c) +
                       s(mean_pH, k = 5) +
                       s(mean_pH, by = exp_day, k = 5) +
                       (1 | crab_id) + (1 | tank),
    data    = mod_data,
    family  = gaussian(),
    prior   = priors_sPH_growth,
    chains  = 4, iter = 3000, warmup = 1500,
    seed    = 20260612,
    control = list(adapt_delta = 0.97, max_treedepth = 12),
    refresh = 0,
    backend = "rstan"
  )
  saveRDS(fit_A_sPH, fit_path_A_sPH)
}

# ------------------------------------------------------------
# Model B_sPH
# ------------------------------------------------------------
fit_path_B_sPH <- "output/models/growth_fit_sPH_all3.rds"
if (file.exists(fit_path_B_sPH)) {
  cat("\nLoading cached growth smooth-pH (B) from", fit_path_B_sPH, "\n")
  fit_B_sPH <- readRDS(fit_path_B_sPH)
} else {
  cat("\nFitting growth smooth-pH Model B...\n")
  fit_B_sPH <- brm(
    formula = log_wm ~ exp_day * (experiment + temp_c) +
                       s(mean_pH, k = 5) +
                       s(mean_pH, by = exp_day, k = 5) +
                       (1 | crab_id) + (1 | tank),
    data    = mod_data_all3,
    family  = gaussian(),
    prior   = priors_sPH_growth,
    chains  = 4, iter = 3000, warmup = 1500,
    seed    = 20260612,
    control = list(adapt_delta = 0.97, max_treedepth = 12),
    refresh = 0,
    backend = "rstan"
  )
  saveRDS(fit_B_sPH, fit_path_B_sPH)
}

cat("\n--- growth smooth-pH Model A summary ---\n")
print(summary(fit_A_sPH))
cat("\n--- growth smooth-pH Model B summary ---\n")
print(summary(fit_B_sPH))

fit_A_sPH <- add_criterion(fit_A_sPH, "loo")
fit_B_sPH <- add_criterion(fit_B_sPH, "loo")

cat("\n== Growth Model A: linear pH vs smooth pH ==\n")
print(loo_compare(fit_A, fit_A_sPH))
cat("\n== Growth Model B: linear pH vs smooth pH ==\n")
print(loo_compare(fit_B, fit_B_sPH))

saveRDS(fit_A_sPH, "output/models/growth_fit_sPH.rds")
saveRDS(fit_B_sPH, "output/models/growth_fit_sPH_all3.rds")

# ------------------------------------------------------------
# Plot: posterior growth rate (log-mass per day) as a function
# of pH, holding experiment at a reference and temperature at
# 10C, marginalising the random effects.
# ------------------------------------------------------------
plot_growth_rate_smooth <- function(fit, data, ref_experiment, out_path,
                                     line_col = "purple4") {
  grid <- tibble(
    mean_pH    = seq(7.45, 8.10, length.out = 80),
    temp_c     = 0,
    experiment = factor(ref_experiment,
                        levels = levels(data$experiment)),
    crab_id    = data$crab_id[1],
    tank       = data$tank[1]
  )
  two <- bind_rows(mutate(grid, exp_day = 0),
                   mutate(grid, exp_day = 100))
  preds <- two |>
    add_epred_draws(fit, ndraws = 800,
                    re_formula = NA, allow_new_levels = TRUE) |>
    ungroup() |>
    select(mean_pH, exp_day, .draw, .epred) |>
    pivot_wider(names_from = exp_day, values_from = .epred,
                names_prefix = "d") |>
    mutate(rate = (d100 - d0) / 100) |>
    group_by(mean_pH) |>
    median_qi(rate, .width = 0.95)

  obs_tanks <- data |>
    distinct(experiment, treatment_pH, treatment_temp, mean_pH)

  yloc <- min(preds$.lower) - (max(preds$.upper) - min(preds$.lower)) * 0.05

  p <- ggplot() +
    geom_ribbon(data = preds,
                aes(x = mean_pH, ymin = .lower, ymax = .upper),
                alpha = 0.22, fill = line_col) +
    geom_line(data = preds,
              aes(x = mean_pH, y = rate),
              colour = line_col, linewidth = 0.9) +
    geom_point(data = obs_tanks,
               aes(x = mean_pH, y = yloc, shape = experiment),
               size = 2.4, colour = "black", fill = "white") +
    scale_shape_manual(values = c("2010-2011" = 21, "2012-2013" = 22,
                                  "2024-2025" = 24),
                       name = "Tank (experiment)") +
    geom_hline(yintercept = 0, linetype = "dashed", colour = "grey50") +
    labs(x = "Mean pH",
         y = "Log-mass growth rate (per day)",
         title = "Posterior smooth: pH effect on log-mass growth rate",
         subtitle = sprintf("Reference experiment: %s, temperature centred at 10°C, random effects marginalised",
                            ref_experiment))
  ggsave(out_path, p, width = 7.5, height = 4.8, dpi = 150)
}

plot_growth_rate_smooth(fit_A_sPH, mod_data,     "2010-2011",
                         "output/figures/growth_smooth_pH.png", "steelblue")
plot_growth_rate_smooth(fit_B_sPH, mod_data_all3, "2024-2025",
                         "output/figures/growth_smooth_pH_all3.png", "purple4")

cat("\nSmooth-pH growth figures written:\n")
cat("  - growth_smooth_pH.png\n")
cat("  - growth_smooth_pH_all3.png\n")
