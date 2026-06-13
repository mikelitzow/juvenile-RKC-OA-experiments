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
# n_initial = 1 so add_epred_draws returns mu (prob of death)
# directly, not expected count.
pred_grid <- mod_data |>
  distinct(tank, experiment, treatment_pH, treatment_temp,
           pH_c, temp_c, mean_pH, mean_temp_C) |>
  tidyr::crossing(day = seq(1, max(mod_data$day), by = 2)) |>
  mutate(log_day = log(day),
         n_initial = 1L)

pred_draws <- pred_grid |>
  add_epred_draws(fit, ndraws = 400, re_formula = NULL) |>
  mutate(prop_alive = 1 - .epred) |>          # cloglog mu = p_dead
  group_by(tank, experiment, treatment_pH, treatment_temp,
           mean_pH, mean_temp_C, day) |>
  median_qi(prop_alive, .width = 0.95)

obs_curve <- mod_data |>
  mutate(prop_alive = n_alive / n_initial)

p_curves <- ggplot() +
  geom_ribbon(data = pred_draws,
              aes(x = day, ymin = .lower, ymax = .upper),
              alpha = 0.25, fill = "steelblue") +
  geom_line(data = pred_draws,
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
       subtitle = "Posterior median +/- 95% CI from binomial hazard model")
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
