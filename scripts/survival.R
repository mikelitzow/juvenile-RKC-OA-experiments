# ============================================================
# survival.R
#
# Bayesian survival analysis of juvenile red king crab in
# response to ocean acidification and warming, using the two
# published experiments only:
#   * 2010-2011 (Long et al. 2013)
#   * 2012-2013 (Swiney et al. 2017)
#
# Model: constant per-tank mortality hazard r[i], with
#   log(r[i]) = b0 + b_exp*1[2012] + b_pH*pH_c + b_T*temp_c
#               + b_int*pH_c*temp_c + u[i]
#   u[i] ~ Normal(0, sigma_tank)
#
# Implemented as a complementary log-log binomial with offset
# log(t):
#   n_died | trials(n_initial) ~ offset(log_day) +
#                                experiment + pH_c*temp_c +
#                                (1 | tank)
#
# Priors are weakly informative; runs in brms / Stan.
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
survival <- read_csv("data/combined/survival_combined.csv",
                     show_col_types = FALSE)

mod_data <- survival |>
  filter(experiment %in% c("2010-2011", "2012-2013"),
         day >= 1) |>
  mutate(
    n_died     = n_initial - n_alive,
    log_day    = log(day),
    tank       = paste(experiment, treatment_pH, treatment_temp, sep = " | "),
    experiment = factor(experiment, levels = c("2010-2011", "2012-2013"))
  )

# Centering values used for pH and temperature.  Rounded to
# biologically meaningful reference points.
PH_CENTER   <- 8.0
TEMP_CENTER <- 10.0
mod_data <- mod_data |>
  mutate(pH_c   = mean_pH    - PH_CENTER,
         temp_c = mean_temp_C - TEMP_CENTER)

cat("--- model data summary ---\n")
cat("n observations:",   nrow(mod_data), "\n")
cat("n tanks:",          n_distinct(mod_data$tank), "\n")
print(mod_data |>
        distinct(experiment, treatment_pH, treatment_temp,
                 mean_pH, mean_temp_C, pH_c, temp_c, tank),
      n = Inf)

# ------------------------------------------------------------
# 2. Specify priors
# ------------------------------------------------------------
priors <- c(
  # log(r) baseline.  Published rates span ~ 0.002 - 0.025/day,
  # i.e. log(r) in roughly (-6.2, -3.7).  Center at -5 with SD 2.
  prior(normal(-5, 2), class = "Intercept"),

  # All other fixed-effect slopes (experiment dummy, pH, temp,
  # interaction).  Weakly informative; lets the data dominate.
  prior(normal(0, 5), class = "b"),

  # Tank-level variance.  Exponential(1) shrinks small SDs
  # toward zero while permitting larger ones if the data
  # demand it.
  prior(exponential(1), class = "sd", group = "tank")
)

# ------------------------------------------------------------
# 3. Fit the model
# ------------------------------------------------------------
fit_path <- "output/models/survival_fit.rds"
if (file.exists(fit_path)) {
  cat("\nLoading cached fit from", fit_path, "\n")
  fit <- readRDS(fit_path)
} else {
  cat("\nFitting model (this may take a minute)...\n")
  # init function: anchor the intercept near log(r) ~ -5 (the
  # range of published mortality rates).  With the log(day)
  # offset, default random inits drive mu to ~1 and the
  # binomial likelihood to -Inf.
  init_fun <- function() {
    list(
      Intercept = -5 + rnorm(1, 0, 0.2),
      b         = rnorm(4, 0, 0.1),
      sd_1      = array(0.3 + abs(rnorm(1, 0, 0.1)), dim = 1),
      z_1       = matrix(rnorm(9, 0, 0.1), nrow = 1, ncol = 9)
    )
  }

  fit <- brm(
    formula = n_died | trials(n_initial) ~
                offset(log_day) + experiment + pH_c * temp_c +
                (1 | tank),
    data     = mod_data,
    family   = binomial(link = "cloglog"),
    prior    = priors,
    chains   = 4, iter = 3000, warmup = 1500,
    seed     = 20260612,
    init     = init_fun,
    control  = list(adapt_delta = 0.95, max_treedepth = 12),
    refresh  = 0,
    backend  = "rstan"
  )
  saveRDS(fit, fit_path)
}

# ------------------------------------------------------------
# 4. Convergence + summary
# ------------------------------------------------------------
cat("\n--- model summary ---\n")
print(summary(fit))

cat("\n--- Rhat range ---\n")
rh <- rhat(fit)
cat("max Rhat:", round(max(rh, na.rm = TRUE), 3),
    "  min ESS bulk:",
    round(min(neff_ratio(fit), na.rm = TRUE) * 6000, 0), "\n")

# Per-tank posterior mortality rates (r), on the natural scale.
# With the cloglog link and offset log(day) = 0, the linear
# predictor IS log(r), so 1 - mu = exp(-r) -> r = -log(1 - mu).
tank_newdata <- mod_data |>
  distinct(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C, pH_c, temp_c) |>
  mutate(n_initial = 1L, log_day = 0)

tank_rates <- tank_newdata |>
  add_epred_draws(fit, re_formula = NULL) |>
  mutate(r = -log(1 - .epred)) |>
  group_by(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C) |>
  median_qi(r, .width = 0.95) |>
  ungroup() |>
  arrange(r)

cat("\n--- posterior per-tank mortality rates (median + 95% CI) ---\n")
print(tank_rates, n = Inf, width = Inf)

# ------------------------------------------------------------
# 5. Plots
# ------------------------------------------------------------
theme_set(theme_bw(base_size = 11))

# 5a. Coefficient plot for fixed effects
coef_draws <- fit |>
  spread_draws(b_Intercept,
               b_experiment2012M2013,
               b_pH_c,
               b_temp_c,
               `b_pH_c:temp_c`,
               sd_tank__Intercept) |>
  pivot_longer(starts_with("b_") | starts_with("sd_"),
               names_to = "parameter", values_to = "value") |>
  mutate(parameter = recode(parameter,
    "b_Intercept"           = "Intercept: log(r) at pH 8.0, 10C, 2010",
    "b_experiment2012M2013" = "Experiment: 2012 vs 2010 (log(r))",
    "b_pH_c"                = "pH (per unit; centered at 8.0)",
    "b_temp_c"              = "Temperature (per C; centered at 10C)",
    "b_pH_c:temp_c"         = "pH x Temperature interaction",
    "sd_tank__Intercept"    = "Tank-level SD"
  ))

p_coef <- ggplot(coef_draws, aes(x = value, y = parameter)) +
  stat_halfeye(.width = c(0.66, 0.95)) +
  geom_vline(xintercept = 0, linetype = "dashed", colour = "grey50") +
  labs(x = "Posterior value (log mortality-rate scale)",
       y = NULL,
       title = "Posterior distributions of fixed effects + tank SD",
       subtitle = "Bayesian binomial hazard model, published RKC OA experiments")
ggsave("output/figures/survival_coefficients.png", p_coef,
       width = 8, height = 4.5, dpi = 150)

# 5b. Observed vs fitted survival curves per tank.
# Two pieces of uncertainty are shown:
#   - Solid line: posterior median of fitted prop_alive (from
#     add_epred_draws with n_initial = 1, where mu = prob of
#     death and prop_alive = 1 - mu).  The credible band on
#     this is so tight (each tank has ~150 daily obs) that it
#     is hidden by the line itself.
#   - Ribbon: 95% posterior PREDICTIVE interval on prop_alive,
#     i.e. add_predicted_draws with the actual n_initial.
#     This adds the binomial sampling noise expected from
#     n_initial = 30 (or 15) crabs at the fitted rate, and is
#     what we expect future observations to scatter inside.
pred_grid_mean <- mod_data |>
  distinct(tank, experiment, treatment_pH, treatment_temp,
           pH_c, temp_c, mean_pH, mean_temp_C) |>
  tidyr::crossing(day = seq(1, max(mod_data$day), by = 2)) |>
  mutate(log_day = log(day),
         n_initial = 1L)

pred_grid_obs <- mod_data |>
  distinct(tank, experiment, treatment_pH, treatment_temp,
           pH_c, temp_c, mean_pH, mean_temp_C, n_initial) |>
  tidyr::crossing(day = seq(1, max(mod_data$day), by = 2)) |>
  mutate(log_day = log(day))

# Posterior median of fitted prop_alive (line)
fit_line <- pred_grid_mean |>
  add_epred_draws(fit, ndraws = 400, re_formula = NULL) |>
  mutate(prop_alive = 1 - .epred) |>
  group_by(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C, day) |>
  median_qi(prop_alive, .width = 0.95)

# Posterior predictive interval on prop_alive (ribbon)
pred_band <- pred_grid_obs |>
  add_predicted_draws(fit, ndraws = 400, re_formula = NULL) |>
  mutate(prop_alive = 1 - .prediction / n_initial) |>  # .prediction = predicted DEATHS
  group_by(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C, day) |>
  median_qi(prop_alive, .width = 0.95)

obs_curve <- mod_data |>
  mutate(prop_alive = n_alive / n_initial)

p_curves <- ggplot() +
  geom_ribbon(data = pred_band,
              aes(x = day, ymin = .lower, ymax = .upper),
              alpha = 0.22, fill = "steelblue") +
  geom_line(data = fit_line,
            aes(x = day, y = prop_alive),
            colour = "steelblue", linewidth = 0.8) +
  geom_point(data = obs_curve,
             aes(x = day, y = prop_alive),
             size = 0.4, alpha = 0.4) +
  facet_wrap(~ tank, ncol = 3) +
  scale_y_continuous(limits = c(0, 1.02),
                     breaks = c(0, 0.25, 0.5, 0.75, 1)) +
  labs(x = "Experimental day",
       y = "Proportion alive",
       title = "Fitted survival vs observations per tank",
       subtitle = "Line: posterior median fitted survival.  Ribbon: 95% posterior predictive interval (incl. binomial sampling noise).")
ggsave("output/figures/survival_observed_vs_predicted.png", p_curves,
       width = 10, height = 6.5, dpi = 150)

# 5c. Hazard-rate surface over the pH x temp space
surface_grid <- crossing(
  mean_pH     = seq(7.45, 8.10, length.out = 40),
  mean_temp_C = seq(7.5,  13,   length.out = 40)
) |>
  mutate(pH_c   = mean_pH    - PH_CENTER,
         temp_c = mean_temp_C - TEMP_CENTER,
         experiment = "2012-2013",      # average effect
         n_initial = 1, log_day = 0)

surface <- surface_grid |>
  add_epred_draws(fit, ndraws = 400, re_formula = NA) |>
  mutate(r = -log(1 - .epred)) |>
  group_by(mean_pH, mean_temp_C) |>
  summarise(r_med = median(r), .groups = "drop")

obs_tanks <- mod_data |>
  distinct(experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C)

p_surface <- ggplot(surface, aes(x = mean_pH, y = mean_temp_C,
                                 fill = r_med)) +
  geom_raster(interpolate = TRUE) +
  geom_contour(aes(z = r_med), colour = "white", alpha = 0.4) +
  geom_point(data = obs_tanks, aes(fill = NULL), shape = 21,
             fill = "white", colour = "black", size = 2.4) +
  scale_fill_viridis_c(option = "magma", direction = -1,
                       trans = "log", breaks = c(0.001, 0.005, 0.02),
                       name = "Daily\nmortality\nrate r") +
  labs(x = "Mean pH (centered at 8.0)",
       y = "Mean temperature (C)",
       title = "Posterior median daily mortality rate over pH x temp",
       subtitle = "Population-level (random effect dropped); observed treatments shown as circles")
ggsave("output/figures/survival_rate_surface.png", p_surface,
       width = 7, height = 5, dpi = 150)

cat("\nFigures written to output/figures/\n")
cat("  - survival_coefficients.png\n")
cat("  - survival_observed_vs_predicted.png\n")
cat("  - survival_rate_surface.png\n")


# ============================================================
# ============================================================
# SECOND ANALYSIS: include the 2024-2025 (unpublished) experiment.
# ------------------------------------------------------------
# This block is purely additive to the analysis above.  Outputs
# carry the suffix "_all3" so they don't overwrite the
# published-only run.  Pooling structure and priors are
# unchanged; the experiment factor now has three levels.
# ============================================================
# ============================================================

mod_data_all3 <- survival |>
  filter(day >= 1) |>
  mutate(
    n_died     = n_initial - n_alive,
    log_day    = log(day),
    tank       = paste(experiment, treatment_pH, treatment_temp, sep = " | "),
    experiment = factor(experiment,
                        levels = c("2010-2011", "2012-2013", "2024-2025"))
  ) |>
  mutate(pH_c   = mean_pH    - PH_CENTER,
         temp_c = mean_temp_C - TEMP_CENTER)

cat("\n=========================================================\n")
cat("Second analysis (all three experiments)\n")
cat("=========================================================\n")
cat("n observations:",   nrow(mod_data_all3), "\n")
cat("n tanks:",          n_distinct(mod_data_all3$tank), "\n")
print(mod_data_all3 |>
        distinct(experiment, treatment_pH, treatment_temp,
                 mean_pH, mean_temp_C, pH_c, temp_c, tank),
      n = Inf)

# ------------------------------------------------------------
# Fit
# ------------------------------------------------------------
# Init function with the correct dimensions for the larger
# model: 5 fixed-effect slopes (2 experiment dummies + pH +
# temp + interaction) and 17 tank random intercepts.
init_fun_all3 <- function() {
  list(
    Intercept = -5 + rnorm(1, 0, 0.2),
    b         = rnorm(5, 0, 0.1),
    sd_1      = array(0.3 + abs(rnorm(1, 0, 0.1)), dim = 1),
    z_1       = matrix(rnorm(17, 0, 0.1), nrow = 1, ncol = 17)
  )
}

fit_path_all3 <- "output/models/survival_fit_all3.rds"
if (file.exists(fit_path_all3)) {
  cat("\nLoading cached all-3 fit from", fit_path_all3, "\n")
  fit_all3 <- readRDS(fit_path_all3)
} else {
  cat("\nFitting all-3 model (this may take a minute)...\n")
  fit_all3 <- brm(
    formula = n_died | trials(n_initial) ~
                offset(log_day) + experiment + pH_c * temp_c +
                (1 | tank),
    data     = mod_data_all3,
    family   = binomial(link = "cloglog"),
    prior    = priors,
    chains   = 4, iter = 3000, warmup = 1500,
    seed     = 20260612,
    init     = init_fun_all3,
    control  = list(adapt_delta = 0.95, max_treedepth = 12),
    refresh  = 0,
    backend  = "rstan"
  )
  saveRDS(fit_all3, fit_path_all3)
}

cat("\n--- all-3 model summary ---\n")
print(summary(fit_all3))

cat("\n--- Rhat range (all-3) ---\n")
rh3 <- rhat(fit_all3)
cat("max Rhat:", round(max(rh3, na.rm = TRUE), 3),
    "  min ESS bulk:",
    round(min(neff_ratio(fit_all3), na.rm = TRUE) * 6000, 0), "\n")

# ------------------------------------------------------------
# Per-tank posterior rates (all-3 model)
# ------------------------------------------------------------
tank_newdata_all3 <- mod_data_all3 |>
  distinct(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C, pH_c, temp_c) |>
  mutate(n_initial = 1L, log_day = 0)

tank_rates_all3 <- tank_newdata_all3 |>
  add_epred_draws(fit_all3, re_formula = NULL) |>
  mutate(r = -log(1 - .epred)) |>
  group_by(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C) |>
  median_qi(r, .width = 0.95) |>
  ungroup() |>
  arrange(r)

cat("\n--- posterior per-tank mortality rates, all 3 experiments ---\n")
print(tank_rates_all3, n = Inf, width = Inf)

# ------------------------------------------------------------
# Plots (all-3)
# ------------------------------------------------------------

# Coefficient plot.  brms names the experiment dummies
# "experiment2012M2013" and "experiment2024M2025".
coef_draws_all3 <- fit_all3 |>
  spread_draws(b_Intercept,
               b_experiment2012M2013,
               b_experiment2024M2025,
               b_pH_c,
               b_temp_c,
               `b_pH_c:temp_c`,
               sd_tank__Intercept) |>
  pivot_longer(starts_with("b_") | starts_with("sd_"),
               names_to = "parameter", values_to = "value") |>
  mutate(parameter = recode(parameter,
    "b_Intercept"           = "Intercept: log(r) at pH 8.0, 10C, 2010",
    "b_experiment2012M2013" = "Experiment: 2012 vs 2010 (log(r))",
    "b_experiment2024M2025" = "Experiment: 2024 vs 2010 (log(r))",
    "b_pH_c"                = "pH (per unit; centered at 8.0)",
    "b_temp_c"              = "Temperature (per C; centered at 10C)",
    "b_pH_c:temp_c"         = "pH x Temperature interaction",
    "sd_tank__Intercept"    = "Tank-level SD"
  ))

p_coef_all3 <- ggplot(coef_draws_all3, aes(x = value, y = parameter)) +
  stat_halfeye(.width = c(0.66, 0.95)) +
  geom_vline(xintercept = 0, linetype = "dashed", colour = "grey50") +
  labs(x = "Posterior value (log mortality-rate scale)",
       y = NULL,
       title = "Posterior fixed effects + tank SD (all 3 experiments)",
       subtitle = "Bayesian binomial hazard model including 2024-2025 data")
ggsave("output/figures/survival_coefficients_all3.png", p_coef_all3,
       width = 8, height = 5, dpi = 150)

# Observed vs fitted survival per tank (17 panels) - using
# posterior predictive interval (incl. binomial sampling noise)
# so the ribbon is visible.  See the published-only block above
# for the diagnostic explanation.
pred_grid_mean_all3 <- mod_data_all3 |>
  distinct(tank, experiment, treatment_pH, treatment_temp,
           pH_c, temp_c, mean_pH, mean_temp_C) |>
  tidyr::crossing(day = seq(1, max(mod_data_all3$day), by = 4)) |>
  mutate(log_day = log(day), n_initial = 1L)

pred_grid_obs_all3 <- mod_data_all3 |>
  distinct(tank, experiment, treatment_pH, treatment_temp,
           pH_c, temp_c, mean_pH, mean_temp_C, n_initial) |>
  tidyr::crossing(day = seq(1, max(mod_data_all3$day), by = 4)) |>
  mutate(log_day = log(day))

fit_line_all3 <- pred_grid_mean_all3 |>
  add_epred_draws(fit_all3, ndraws = 400, re_formula = NULL) |>
  mutate(prop_alive = 1 - .epred) |>
  group_by(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C, day) |>
  median_qi(prop_alive, .width = 0.95)

pred_band_all3 <- pred_grid_obs_all3 |>
  add_predicted_draws(fit_all3, ndraws = 400, re_formula = NULL) |>
  mutate(prop_alive = 1 - .prediction / n_initial) |>  # .prediction = predicted DEATHS
  group_by(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C, day) |>
  median_qi(prop_alive, .width = 0.95)

obs_curve_all3 <- mod_data_all3 |>
  mutate(prop_alive = n_alive / n_initial)

p_curves_all3 <- ggplot() +
  geom_ribbon(data = pred_band_all3,
              aes(x = day, ymin = .lower, ymax = .upper),
              alpha = 0.22, fill = "steelblue") +
  geom_line(data = fit_line_all3,
            aes(x = day, y = prop_alive),
            colour = "steelblue", linewidth = 0.6) +
  geom_point(data = obs_curve_all3,
             aes(x = day, y = prop_alive),
             size = 0.3, alpha = 0.35) +
  facet_wrap(~ tank, ncol = 4) +
  scale_y_continuous(limits = c(0, 1.02),
                     breaks = c(0, 0.5, 1)) +
  labs(x = "Experimental day",
       y = "Proportion alive",
       title = "Fitted survival vs observations per tank (all 3 experiments)",
       subtitle = "Line: posterior median fitted survival.  Ribbon: 95% predictive interval (binomial noise).  2024-25 A/A censored at d 117.")
ggsave("output/figures/survival_observed_vs_predicted_all3.png", p_curves_all3,
       width = 12, height = 9, dpi = 150)

# Hazard-rate surface, expanded to the realised range across
# all three experiments.
surface_grid_all3 <- crossing(
  mean_pH     = seq(7.45, 8.10, length.out = 50),
  mean_temp_C = seq(7.0,  13,   length.out = 50)
) |>
  mutate(pH_c   = mean_pH    - PH_CENTER,
         temp_c = mean_temp_C - TEMP_CENTER,
         experiment = "2024-2025",     # population-level (RE dropped)
         n_initial = 1L, log_day = 0)

surface_all3 <- surface_grid_all3 |>
  add_epred_draws(fit_all3, ndraws = 400, re_formula = NA) |>
  mutate(r = -log(1 - .epred)) |>
  group_by(mean_pH, mean_temp_C) |>
  summarise(r_med = median(r), .groups = "drop")

obs_tanks_all3 <- mod_data_all3 |>
  distinct(experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C)

p_surface_all3 <- ggplot(surface_all3,
                         aes(x = mean_pH, y = mean_temp_C, fill = r_med)) +
  geom_raster(interpolate = TRUE) +
  geom_contour(aes(z = r_med), colour = "white", alpha = 0.4) +
  geom_point(data = obs_tanks_all3,
             aes(fill = NULL, shape = experiment),
             colour = "black", fill = "white", size = 2.4) +
  scale_fill_viridis_c(option = "magma", direction = -1,
                       trans = "log", breaks = c(0.001, 0.005, 0.02),
                       name = "Daily\nmortality\nrate r") +
  scale_shape_manual(values = c("2010-2011" = 21, "2012-2013" = 22,
                                "2024-2025" = 24),
                     name = "Experiment") +
  labs(x = "Mean pH",
       y = "Mean temperature (C)",
       title = "Posterior median daily mortality rate, all 3 experiments",
       subtitle = "Population-level surface (random effect dropped); observed treatments overlaid")
ggsave("output/figures/survival_rate_surface_all3.png", p_surface_all3,
       width = 8, height = 5, dpi = 150)

cat("\nAll-3 figures written:\n")
cat("  - survival_coefficients_all3.png\n")
cat("  - survival_observed_vs_predicted_all3.png\n")
cat("  - survival_rate_surface_all3.png\n")


# ============================================================
# ============================================================
# THIRD ANALYSIS: Weibull (non-constant) hazard.
# ------------------------------------------------------------
# The constant-hazard model assumes log(r) does not vary with
# time.  Some treatments — notably the 2010 pH 7.5 cohort —
# show a delayed mortality cliff that is poorly captured by a
# constant rate.  A Weibull hazard relaxes that assumption:
#
#   P(alive at t) = exp(-(r0 * t)^k)
#   cloglog(P_dead) = k * log(t) + k * log(r0)
#
# So in the cloglog binomial GLM, the offset(log_day) is
# replaced by a free coefficient k * log_day.  k > 1 means
# hazard increasing with time (delayed mortality), k < 1 means
# hazard decreasing with time (early die-off then plateau),
# k = 1 recovers the constant-hazard model.
#
# Fits both Model A (published only) and Model B (all 3),
# compares to the constant-hazard fits via leave-one-out
# cross-validation, and saves figures with the _weibull suffix.
# ============================================================
# ============================================================

priors_weibull <- c(
  prior(normal(-5, 2), class = "Intercept"),
  prior(normal(1, 0.5), class = "b", coef = "log_day"),   # k centered at 1
  prior(normal(0, 5),   class = "b"),
  prior(exponential(1), class = "sd", group = "tank")
)

# ------------------------------------------------------------
# Model A (Weibull, published only)
# ------------------------------------------------------------
init_fun_w <- function() {
  list(
    Intercept = -5 + rnorm(1, 0, 0.2),
    b         = c(1, rnorm(4, 0, 0.1)),       # 1st b is log_day (k)
    sd_1      = array(0.3 + abs(rnorm(1, 0, 0.1)), dim = 1),
    z_1       = matrix(rnorm(9, 0, 0.1), nrow = 1, ncol = 9)
  )
}

fit_path_w <- "output/models/survival_fit_weibull.rds"
if (file.exists(fit_path_w)) {
  cat("\nLoading cached Weibull (A) fit from", fit_path_w, "\n")
  fit_w <- readRDS(fit_path_w)
} else {
  cat("\nFitting Weibull Model A (published only)...\n")
  fit_w <- brm(
    formula = n_died | trials(n_initial) ~
                log_day + experiment + pH_c * temp_c +
                (1 | tank),
    data     = mod_data,
    family   = binomial(link = "cloglog"),
    prior    = priors_weibull,
    chains   = 4, iter = 3000, warmup = 1500,
    seed     = 20260612,
    init     = init_fun_w,
    control  = list(adapt_delta = 0.97, max_treedepth = 12),
    refresh  = 0,
    backend  = "rstan"
  )
  saveRDS(fit_w, fit_path_w)
}

# ------------------------------------------------------------
# Model B (Weibull, all 3 experiments)
# ------------------------------------------------------------
init_fun_w_all3 <- function() {
  list(
    Intercept = -5 + rnorm(1, 0, 0.2),
    b         = c(1, rnorm(5, 0, 0.1)),       # 1st b is log_day (k)
    sd_1      = array(0.3 + abs(rnorm(1, 0, 0.1)), dim = 1),
    z_1       = matrix(rnorm(17, 0, 0.1), nrow = 1, ncol = 17)
  )
}

fit_path_w_all3 <- "output/models/survival_fit_weibull_all3.rds"
if (file.exists(fit_path_w_all3)) {
  cat("\nLoading cached Weibull (B) fit from", fit_path_w_all3, "\n")
  fit_w_all3 <- readRDS(fit_path_w_all3)
} else {
  cat("\nFitting Weibull Model B (all 3 experiments)...\n")
  fit_w_all3 <- brm(
    formula = n_died | trials(n_initial) ~
                log_day + experiment + pH_c * temp_c +
                (1 | tank),
    data     = mod_data_all3,
    family   = binomial(link = "cloglog"),
    prior    = priors_weibull,
    chains   = 4, iter = 3000, warmup = 1500,
    seed     = 20260612,
    init     = init_fun_w_all3,
    control  = list(adapt_delta = 0.97, max_treedepth = 12),
    refresh  = 0,
    backend  = "rstan"
  )
  saveRDS(fit_w_all3, fit_path_w_all3)
}

cat("\n--- Weibull Model A summary (published only) ---\n")
print(summary(fit_w))
cat("\n--- Weibull Model B summary (all 3) ---\n")
print(summary(fit_w_all3))

# ------------------------------------------------------------
# Model comparison: LOO
# ------------------------------------------------------------
cat("\n--- Leave-one-out cross-validation ---\n")

fit       <- add_criterion(fit,       "loo")
fit_w     <- add_criterion(fit_w,     "loo")
fit_all3  <- add_criterion(fit_all3,  "loo")
fit_w_all3 <- add_criterion(fit_w_all3, "loo")

cat("\n== Model A (published only): constant vs Weibull ==\n")
print(loo_compare(fit, fit_w))

cat("\n== Model B (all 3 experiments): constant vs Weibull ==\n")
print(loo_compare(fit_all3, fit_w_all3))

# Cache the criterion-augmented fits
saveRDS(fit,        "output/models/survival_fit.rds")
saveRDS(fit_w,      "output/models/survival_fit_weibull.rds")
saveRDS(fit_all3,   "output/models/survival_fit_all3.rds")
saveRDS(fit_w_all3, "output/models/survival_fit_weibull_all3.rds")

# ------------------------------------------------------------
# Plots: Weibull observed-vs-predicted (Model A)
# ------------------------------------------------------------
fit_line_w <- pred_grid_mean |>
  add_epred_draws(fit_w, ndraws = 400, re_formula = NULL) |>
  mutate(prop_alive = 1 - .epred) |>
  group_by(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C, day) |>
  median_qi(prop_alive, .width = 0.95)

pred_band_w <- pred_grid_obs |>
  add_predicted_draws(fit_w, ndraws = 400, re_formula = NULL) |>
  mutate(prop_alive = 1 - .prediction / n_initial) |>  # .prediction = predicted DEATHS
  group_by(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C, day) |>
  median_qi(prop_alive, .width = 0.95)

p_curves_w <- ggplot() +
  geom_ribbon(data = pred_band_w,
              aes(x = day, ymin = .lower, ymax = .upper),
              alpha = 0.22, fill = "darkorange") +
  geom_line(data = fit_line_w,
            aes(x = day, y = prop_alive),
            colour = "darkorange", linewidth = 0.8) +
  geom_point(data = obs_curve,
             aes(x = day, y = prop_alive),
             size = 0.4, alpha = 0.4) +
  facet_wrap(~ tank, ncol = 3) +
  scale_y_continuous(limits = c(0, 1.02),
                     breaks = c(0, 0.25, 0.5, 0.75, 1)) +
  labs(x = "Experimental day",
       y = "Proportion alive",
       title = "Fitted survival vs observations per tank (Weibull, Model A)",
       subtitle = "Line: posterior median.  Ribbon: 95% posterior predictive interval.")
ggsave("output/figures/survival_observed_vs_predicted_weibull.png", p_curves_w,
       width = 10, height = 6.5, dpi = 150)

# ------------------------------------------------------------
# Plots: Weibull observed-vs-predicted (Model B)
# ------------------------------------------------------------
fit_line_w_all3 <- pred_grid_mean_all3 |>
  add_epred_draws(fit_w_all3, ndraws = 400, re_formula = NULL) |>
  mutate(prop_alive = 1 - .epred) |>
  group_by(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C, day) |>
  median_qi(prop_alive, .width = 0.95)

pred_band_w_all3 <- pred_grid_obs_all3 |>
  add_predicted_draws(fit_w_all3, ndraws = 400, re_formula = NULL) |>
  mutate(prop_alive = 1 - .prediction / n_initial) |>  # .prediction = predicted DEATHS
  group_by(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C, day) |>
  median_qi(prop_alive, .width = 0.95)

p_curves_w_all3 <- ggplot() +
  geom_ribbon(data = pred_band_w_all3,
              aes(x = day, ymin = .lower, ymax = .upper),
              alpha = 0.22, fill = "darkorange") +
  geom_line(data = fit_line_w_all3,
            aes(x = day, y = prop_alive),
            colour = "darkorange", linewidth = 0.6) +
  geom_point(data = obs_curve_all3,
             aes(x = day, y = prop_alive),
             size = 0.3, alpha = 0.35) +
  facet_wrap(~ tank, ncol = 4) +
  scale_y_continuous(limits = c(0, 1.02),
                     breaks = c(0, 0.5, 1)) +
  labs(x = "Experimental day",
       y = "Proportion alive",
       title = "Fitted survival vs observations per tank (Weibull, Model B)",
       subtitle = "All 3 experiments.  Line: posterior median.  Ribbon: 95% posterior predictive interval.")
ggsave("output/figures/survival_observed_vs_predicted_weibull_all3.png",
       p_curves_w_all3, width = 12, height = 9, dpi = 150)

# Quick summary of the k parameter (the shape coefficient)
cat("\n--- Weibull shape parameter k (log_day coefficient) ---\n")
k_summary <- bind_rows(
  fit_w     |> as_draws_df() |> select(k = b_log_day) |> mutate(model = "Model A (published)"),
  fit_w_all3 |> as_draws_df() |> select(k = b_log_day) |> mutate(model = "Model B (all 3)")
) |>
  group_by(model) |>
  median_qi(k, .width = 0.95)
print(k_summary)

cat("\nWeibull figures written:\n")
cat("  - survival_observed_vs_predicted_weibull.png\n")
cat("  - survival_observed_vs_predicted_weibull_all3.png\n")


# ============================================================
# ============================================================
# FOURTH ANALYSIS: Weibull with initial wet mass as a
# tank-level covariate.
# ------------------------------------------------------------
# Hypothesis test for the 2024 baseline shift: how much of the
# experiment effect goes through differences in mean initial
# crab size?
#
# Initial mass is the molt_num == 0 row in wet_mass_combined.
# Per-tank means are: 2010 ambient ~0.010 g, 2010 pH 7.8
# ~0.009 g, 2010 pH 7.5 (no data; imputed as the mean of the
# other two 2010 tanks because all 2010 crabs came from one
# Bristol Bay cohort).  2012 tanks ~0.018-0.020 g; 2024 tanks
# ~0.008-0.011 g.
#
# log(mean_mass) is centered at the grand mean of the
# 16-tank set (excluding the imputed pH 7.5 cell) so the
# intercept has the same biological meaning as in earlier
# fits.  Outputs are suffixed _weibull_mass.
# ============================================================
# ============================================================

wet_mass <- read_csv("data/combined/wet_mass_combined.csv",
                     show_col_types = FALSE)

tank_mass <- wet_mass |>
  filter(molt_num == 0) |>
  group_by(experiment, treatment_pH, treatment_temp) |>
  summarise(mean_initial_mass_g = mean(wet_mass_g, na.rm = TRUE),
            n_initial_obs       = n(),
            .groups = "drop")

# Impute the 2010 pH 7.5 cell with the mean of the other 2010 tanks.
imp_2010 <- mean(tank_mass$mean_initial_mass_g[tank_mass$experiment == "2010-2011"])
tank_mass <- tank_mass |>
  bind_rows(tibble(experiment = "2010-2011",
                   treatment_pH = "pH 7.5",
                   treatment_temp = "ambient",
                   mean_initial_mass_g = imp_2010,
                   n_initial_obs = 0L))

# Centering value: grand mean of log(mass) across observed tanks
# (excluding the imputed value).
LOG_MASS_CENTER <- mean(log(tank_mass$mean_initial_mass_g[tank_mass$n_initial_obs > 0]))

tank_mass <- tank_mass |>
  mutate(log_mass_c = log(mean_initial_mass_g) - LOG_MASS_CENTER)

cat("\n=========================================================\n")
cat("Initial-mass covariate (tank-level mean)\n")
cat("=========================================================\n")
print(tank_mass |> arrange(experiment, treatment_pH, treatment_temp), n = Inf)
cat("Centering: log_mass_c = log(mass) - ", round(LOG_MASS_CENTER, 4),
    "  (grand mean of log mass for 16 observed tanks)\n")

# Join into the model frames.
mod_data_mass <- mod_data |>
  left_join(tank_mass |>
              select(experiment, treatment_pH, treatment_temp, log_mass_c) |>
              mutate(experiment = factor(experiment,
                                         levels = levels(mod_data$experiment))),
            by = c("experiment", "treatment_pH", "treatment_temp"))

mod_data_mass_all3 <- mod_data_all3 |>
  left_join(tank_mass |>
              select(experiment, treatment_pH, treatment_temp, log_mass_c) |>
              mutate(experiment = factor(experiment,
                                         levels = levels(mod_data_all3$experiment))),
            by = c("experiment", "treatment_pH", "treatment_temp"))

stopifnot(all(!is.na(mod_data_mass$log_mass_c)),
          all(!is.na(mod_data_mass_all3$log_mass_c)))

priors_weibull_mass <- c(
  prior(normal(-5, 2), class = "Intercept"),
  prior(normal(1, 0.5), class = "b", coef = "log_day"),
  prior(normal(0, 5),   class = "b"),
  prior(exponential(1), class = "sd", group = "tank")
)

# ------------------------------------------------------------
# Model A_mass (Weibull, published only, with log_mass_c)
# ------------------------------------------------------------
init_fun_wm <- function() {
  list(
    Intercept = -5 + rnorm(1, 0, 0.2),
    b         = c(1, rnorm(5, 0, 0.1)),     # log_day + 4 (exp, pH, temp, int) + 1 (log_mass)
    sd_1      = array(0.3 + abs(rnorm(1, 0, 0.1)), dim = 1),
    z_1       = matrix(rnorm(9, 0, 0.1), nrow = 1, ncol = 9)
  )
}

fit_path_wm <- "output/models/survival_fit_weibull_mass.rds"
if (file.exists(fit_path_wm)) {
  cat("\nLoading cached Weibull+mass (A) fit from", fit_path_wm, "\n")
  fit_wm <- readRDS(fit_path_wm)
} else {
  cat("\nFitting Weibull+mass Model A...\n")
  fit_wm <- brm(
    formula = n_died | trials(n_initial) ~
                log_day + experiment + pH_c * temp_c + log_mass_c +
                (1 | tank),
    data     = mod_data_mass,
    family   = binomial(link = "cloglog"),
    prior    = priors_weibull_mass,
    chains   = 4, iter = 3000, warmup = 1500,
    seed     = 20260612,
    init     = init_fun_wm,
    control  = list(adapt_delta = 0.97, max_treedepth = 12),
    refresh  = 0,
    backend  = "rstan"
  )
  saveRDS(fit_wm, fit_path_wm)
}

# ------------------------------------------------------------
# Model B_mass (Weibull, all 3 experiments, with log_mass_c)
# ------------------------------------------------------------
init_fun_wm_all3 <- function() {
  list(
    Intercept = -5 + rnorm(1, 0, 0.2),
    b         = c(1, rnorm(6, 0, 0.1)),     # log_day + 5 (2 exp dummies, pH, temp, int) + 1 (log_mass)
    sd_1      = array(0.3 + abs(rnorm(1, 0, 0.1)), dim = 1),
    z_1       = matrix(rnorm(17, 0, 0.1), nrow = 1, ncol = 17)
  )
}

fit_path_wm_all3 <- "output/models/survival_fit_weibull_mass_all3.rds"
if (file.exists(fit_path_wm_all3)) {
  cat("\nLoading cached Weibull+mass (B) fit from", fit_path_wm_all3, "\n")
  fit_wm_all3 <- readRDS(fit_path_wm_all3)
} else {
  cat("\nFitting Weibull+mass Model B...\n")
  fit_wm_all3 <- brm(
    formula = n_died | trials(n_initial) ~
                log_day + experiment + pH_c * temp_c + log_mass_c +
                (1 | tank),
    data     = mod_data_mass_all3,
    family   = binomial(link = "cloglog"),
    prior    = priors_weibull_mass,
    chains   = 4, iter = 3000, warmup = 1500,
    seed     = 20260612,
    init     = init_fun_wm_all3,
    control  = list(adapt_delta = 0.97, max_treedepth = 12),
    refresh  = 0,
    backend  = "rstan"
  )
  saveRDS(fit_wm_all3, fit_path_wm_all3)
}

cat("\n--- Weibull+mass Model A summary ---\n")
print(summary(fit_wm))
cat("\n--- Weibull+mass Model B summary ---\n")
print(summary(fit_wm_all3))

# ------------------------------------------------------------
# LOO comparison: does the covariate improve out-of-sample
# predictive performance?
# ------------------------------------------------------------
cat("\n--- LOO comparison: Weibull vs Weibull+mass ---\n")
fit_wm      <- add_criterion(fit_wm,      "loo")
fit_wm_all3 <- add_criterion(fit_wm_all3, "loo")

cat("\n== Model A: Weibull vs Weibull+mass ==\n")
print(loo_compare(fit_w, fit_wm))

cat("\n== Model B: Weibull vs Weibull+mass ==\n")
print(loo_compare(fit_w_all3, fit_wm_all3))

saveRDS(fit_wm,      "output/models/survival_fit_weibull_mass.rds")
saveRDS(fit_wm_all3, "output/models/survival_fit_weibull_mass_all3.rds")

# ------------------------------------------------------------
# Coefficient comparison: how does adding mass change the
# experiment and pH effects?
# ------------------------------------------------------------
cat("\n--- Effect-size comparison (median [95% CI]) ---\n")
extract_summary <- function(fit, model_label) {
  s <- as_draws_df(fit) |> as_tibble() |>
    select(any_of(c("b_log_day",
                    "b_experiment2012M2013",
                    "b_experiment2024M2025",
                    "b_pH_c",
                    "b_temp_c",
                    "b_pH_c:temp_c",
                    "b_log_mass_c")))
  tibble(
    model = model_label,
    parameter = names(s),
    median = round(sapply(s, median), 3),
    lower  = round(sapply(s, quantile, 0.025), 3),
    upper  = round(sapply(s, quantile, 0.975), 3)
  )
}
comparison <- bind_rows(
  extract_summary(fit_w,      "Model A (no mass)"),
  extract_summary(fit_wm,     "Model A (with mass)"),
  extract_summary(fit_w_all3, "Model B (no mass)"),
  extract_summary(fit_wm_all3,"Model B (with mass)")
)
print(comparison, n = Inf)

# ------------------------------------------------------------
# Plots
# ------------------------------------------------------------
fit_line_wm <- pred_grid_mean |>
  left_join(tank_mass |>
              mutate(experiment = factor(experiment,
                                         levels = levels(mod_data$experiment))) |>
              select(experiment, treatment_pH, treatment_temp, log_mass_c),
            by = c("experiment", "treatment_pH", "treatment_temp")) |>
  add_epred_draws(fit_wm, ndraws = 400, re_formula = NULL) |>
  mutate(prop_alive = 1 - .epred) |>
  group_by(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C, day) |>
  median_qi(prop_alive, .width = 0.95)

pred_band_wm <- pred_grid_obs |>
  left_join(tank_mass |>
              mutate(experiment = factor(experiment,
                                         levels = levels(mod_data$experiment))) |>
              select(experiment, treatment_pH, treatment_temp, log_mass_c),
            by = c("experiment", "treatment_pH", "treatment_temp")) |>
  add_predicted_draws(fit_wm, ndraws = 400, re_formula = NULL) |>
  mutate(prop_alive = 1 - .prediction / n_initial) |>
  group_by(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C, day) |>
  median_qi(prop_alive, .width = 0.95)

p_curves_wm <- ggplot() +
  geom_ribbon(data = pred_band_wm,
              aes(x = day, ymin = .lower, ymax = .upper),
              alpha = 0.22, fill = "purple4") +
  geom_line(data = fit_line_wm,
            aes(x = day, y = prop_alive),
            colour = "purple4", linewidth = 0.8) +
  geom_point(data = obs_curve,
             aes(x = day, y = prop_alive),
             size = 0.4, alpha = 0.4) +
  facet_wrap(~ tank, ncol = 3) +
  scale_y_continuous(limits = c(0, 1.02),
                     breaks = c(0, 0.25, 0.5, 0.75, 1)) +
  labs(x = "Experimental day",
       y = "Proportion alive",
       title = "Model A (Weibull + initial mass): observed vs fitted",
       subtitle = "Line: posterior median.  Ribbon: 95% posterior predictive interval.")
ggsave("output/figures/survival_observed_vs_predicted_weibull_mass.png",
       p_curves_wm, width = 10, height = 6.5, dpi = 150)

fit_line_wm_all3 <- pred_grid_mean_all3 |>
  left_join(tank_mass |>
              mutate(experiment = factor(experiment,
                                         levels = levels(mod_data_all3$experiment))) |>
              select(experiment, treatment_pH, treatment_temp, log_mass_c),
            by = c("experiment", "treatment_pH", "treatment_temp")) |>
  add_epred_draws(fit_wm_all3, ndraws = 400, re_formula = NULL) |>
  mutate(prop_alive = 1 - .epred) |>
  group_by(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C, day) |>
  median_qi(prop_alive, .width = 0.95)

pred_band_wm_all3 <- pred_grid_obs_all3 |>
  left_join(tank_mass |>
              mutate(experiment = factor(experiment,
                                         levels = levels(mod_data_all3$experiment))) |>
              select(experiment, treatment_pH, treatment_temp, log_mass_c),
            by = c("experiment", "treatment_pH", "treatment_temp")) |>
  add_predicted_draws(fit_wm_all3, ndraws = 400, re_formula = NULL) |>
  mutate(prop_alive = 1 - .prediction / n_initial) |>
  group_by(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C, day) |>
  median_qi(prop_alive, .width = 0.95)

p_curves_wm_all3 <- ggplot() +
  geom_ribbon(data = pred_band_wm_all3,
              aes(x = day, ymin = .lower, ymax = .upper),
              alpha = 0.22, fill = "purple4") +
  geom_line(data = fit_line_wm_all3,
            aes(x = day, y = prop_alive),
            colour = "purple4", linewidth = 0.6) +
  geom_point(data = obs_curve_all3,
             aes(x = day, y = prop_alive),
             size = 0.3, alpha = 0.35) +
  facet_wrap(~ tank, ncol = 4) +
  scale_y_continuous(limits = c(0, 1.02),
                     breaks = c(0, 0.5, 1)) +
  labs(x = "Experimental day",
       y = "Proportion alive",
       title = "Model B (Weibull + initial mass): observed vs fitted",
       subtitle = "All three experiments.  Line: posterior median.  Ribbon: 95% posterior predictive interval.")
ggsave("output/figures/survival_observed_vs_predicted_weibull_mass_all3.png",
       p_curves_wm_all3, width = 12, height = 9, dpi = 150)

# Save the comparison table for the writeup
write_csv(comparison, "output/coefficient_comparison.csv")

cat("\nMass-covariate figures written:\n")
cat("  - survival_observed_vs_predicted_weibull_mass.png\n")
cat("  - survival_observed_vs_predicted_weibull_mass_all3.png\n")


# ============================================================
# ============================================================
# FIFTH ANALYSIS: smooth pH (threshold test).
# ------------------------------------------------------------
# The 2024-25 design has four pH treatments (7.55, 7.65, 7.85,
# ambient) crossed with two temperatures, giving the resolution
# to detect threshold or otherwise nonlinear pH effects.  This
# block refits Models A and B with the linear pH terms (and
# pH*temp interaction) replaced by a Bayesian thin-plate
# smooth over mean_pH.  Temperature is held as a linear
# covariate (per the question: "let pH vary; hold temperature
# effects constant").
#
# Outputs are suffixed _sPH.
# ============================================================
# ============================================================

priors_sPH <- c(
  prior(normal(-5, 2), class = "Intercept"),
  prior(normal(1, 0.5), class = "b", coef = "log_day"),
  prior(normal(0, 5),   class = "b"),
  prior(exponential(1), class = "sd",  group = "tank"),
  prior(student_t(3, 0, 1), class = "sds")   # prior on smooth wiggliness
)

# ------------------------------------------------------------
# Model A_sPH (Weibull, published only)
# ------------------------------------------------------------
fit_path_sPH <- "output/models/survival_fit_weibull_sPH.rds"
if (file.exists(fit_path_sPH)) {
  cat("\nLoading cached smooth-pH (A) fit from", fit_path_sPH, "\n")
  fit_sPH <- readRDS(fit_path_sPH)
} else {
  cat("\nFitting smooth-pH Model A (published only)...\n")
  fit_sPH <- brm(
    formula = n_died | trials(n_initial) ~
                log_day + experiment + s(mean_pH, k = 5) + temp_c +
                (1 | tank),
    data     = mod_data,
    family   = binomial(link = "cloglog"),
    prior    = priors_sPH,
    chains   = 4, iter = 3000, warmup = 1500,
    seed     = 20260612,
    control  = list(adapt_delta = 0.97, max_treedepth = 12),
    refresh  = 0,
    backend  = "rstan"
  )
  saveRDS(fit_sPH, fit_path_sPH)
}

# ------------------------------------------------------------
# Model B_sPH (Weibull, all 3 experiments)
# ------------------------------------------------------------
fit_path_sPH_all3 <- "output/models/survival_fit_weibull_sPH_all3.rds"
if (file.exists(fit_path_sPH_all3)) {
  cat("\nLoading cached smooth-pH (B) fit from", fit_path_sPH_all3, "\n")
  fit_sPH_all3 <- readRDS(fit_path_sPH_all3)
} else {
  cat("\nFitting smooth-pH Model B (all 3 experiments)...\n")
  fit_sPH_all3 <- brm(
    formula = n_died | trials(n_initial) ~
                log_day + experiment + s(mean_pH, k = 5) + temp_c +
                (1 | tank),
    data     = mod_data_all3,
    family   = binomial(link = "cloglog"),
    prior    = priors_sPH,
    chains   = 4, iter = 3000, warmup = 1500,
    seed     = 20260612,
    control  = list(adapt_delta = 0.97, max_treedepth = 12),
    refresh  = 0,
    backend  = "rstan"
  )
  saveRDS(fit_sPH_all3, fit_path_sPH_all3)
}

cat("\n--- smooth-pH Model A summary ---\n")
print(summary(fit_sPH))
cat("\n--- smooth-pH Model B summary ---\n")
print(summary(fit_sPH_all3))

# ------------------------------------------------------------
# LOO comparison: linear pH vs smooth pH (for both designs)
# ------------------------------------------------------------
fit_sPH      <- add_criterion(fit_sPH,      "loo")
fit_sPH_all3 <- add_criterion(fit_sPH_all3, "loo")

cat("\n== Survival Model A: linear pH (Weibull) vs smooth pH ==\n")
print(loo_compare(fit_w, fit_sPH))
cat("\n== Survival Model B: linear pH (Weibull) vs smooth pH ==\n")
print(loo_compare(fit_w_all3, fit_sPH_all3))

saveRDS(fit_sPH,      "output/models/survival_fit_weibull_sPH.rds")
saveRDS(fit_sPH_all3, "output/models/survival_fit_weibull_sPH_all3.rds")

# ------------------------------------------------------------
# Plot: posterior smooth of log(r) over pH, holding other
# covariates at typical values (temp at 10 C; experiment at
# reference 2010 for A, at 2024 for B; tank RE marginalised).
# ------------------------------------------------------------
plot_smooth_pH <- function(fit, data, ref_experiment, out_path,
                            line_col = "darkgreen") {
  grid <- tibble(
    mean_pH = seq(7.45, 8.10, length.out = 80),
    temp_c     = 0,
    log_day    = 0,
    n_initial  = 1L,
    experiment = factor(ref_experiment,
                        levels = levels(data$experiment))
  )
  draws <- grid |>
    add_epred_draws(fit, ndraws = 800,
                    re_formula = NA, allow_new_levels = TRUE) |>
    mutate(log_r = log(-log(1 - .epred))) |>
    group_by(mean_pH) |>
    median_qi(log_r, .width = 0.95)

  obs_tanks <- data |>
    distinct(experiment, treatment_pH, treatment_temp, mean_pH) |>
    mutate(line_at_obs = -7.5)

  p <- ggplot() +
    geom_ribbon(data = draws,
                aes(x = mean_pH, ymin = .lower, ymax = .upper),
                alpha = 0.22, fill = line_col) +
    geom_line(data = draws,
              aes(x = mean_pH, y = log_r),
              colour = line_col, linewidth = 0.9) +
    geom_point(data = obs_tanks,
               aes(x = mean_pH, y = line_at_obs, shape = experiment),
               size = 2.4, colour = "black", fill = "white") +
    scale_shape_manual(values = c("2010-2011" = 21, "2012-2013" = 22,
                                  "2024-2025" = 24),
                       name = "Tank (experiment)") +
    labs(x = "Mean pH",
         y = "log(daily mortality rate r) at day 1",
         title = "Posterior smooth: pH effect on log mortality rate",
         subtitle = sprintf("Reference experiment: %s, temperature centred at 10°C, tank RE marginalised",
                            ref_experiment))
  ggsave(out_path, p, width = 7.5, height = 4.8, dpi = 150)
}

plot_smooth_pH(fit_sPH,      mod_data,     "2010-2011",
               "output/figures/survival_smooth_pH.png", "steelblue")
plot_smooth_pH(fit_sPH_all3, mod_data_all3, "2024-2025",
               "output/figures/survival_smooth_pH_all3.png", "darkorange")

cat("\nSmooth-pH survival figures written:\n")
cat("  - survival_smooth_pH.png\n")
cat("  - survival_smooth_pH_all3.png\n")
