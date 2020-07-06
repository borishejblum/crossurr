xfit_dr <- function(ds,
                    xvars,
                    yname,
                    aname,
                    K = 5,
                    outcome_learners,
                    ps_learners,
                    interaction_model = TRUE,
                    trim_at = 0.05,
                    outcome_family = gaussian(),
                    ...) {
  yn <- enquo(yname)
  an <- enquo(aname)
  if (interaction_model) {
    mu0 <- xfit_sl(ds = ds,
                   xvars = xvars,
                   yname = yn,
                   K = K,
                   out_name = 'mu0',
                   learners = outcome_learners,
                   control_only = TRUE,
                   aname = an,
                   family = outcome_family,
                   ...) %>%
      select(-fold)
    mu1 <- xfit_sl(ds = ds,
                   xvars = xvars,
                   yname = yn,
                   K = K,
                   out_name = 'mu1',
                   learners = outcome_learners,
                   case_only = TRUE,
                   aname = an,
                   family = outcome_family,
                   ...) %>%
      select(-fold)
  } else {
    mu <- xfit_sl(ds = ds,
                  xvars = c(xvars, aname),
                  yname = yn,
                  K = K,
                  out_name = 'mu',
                  learners = outcome_learners,
                  both_arms = TRUE,
                  aname = an,
                  family = outcome_family,
                  ...) %>%
      select(-fold)
  }

  ps <- xfit_sl(ds = ds,
                    xvars = xvars,
                    yname = an,
                K = K,
                    out_name = 'pi',
                    learners = ps_learners,
                    family = binomial(), ...) %>%
    select(-fold)
  if (trim_at != 0) {
    ps <- ps %>%
      mutate(pi = case_when(pi < trim_at ~ trim_at,
                            pi > 1 - trim_at ~ 1 - trim_at,
                            TRUE ~ pi))
  }
  if (!interaction_model) {
    out_ds <- mu %>%
      inner_join(ps) %>%
      mutate(u_i = mu1 - mu0 +
               (!!an)*((!!yn) - mu1)/pi -
               (1-(!!an))*((!!yn)-mu0)/(1-pi))
  } else {
    out_ds <- mu0 %>%
      inner_join(mu1) %>%
      inner_join(ps) %>%
      mutate(u_i = mu1 - mu0 +
               (!!an)*((!!yn) - mu1)/pi -
               (1-(!!an))*((!!yn)-mu0)/(1-pi))
  }

  out_ds %>%
    summarise(estimate = mean(u_i),
           # sigmasq = mean(u_i^2),
           se = sqrt(mean(u_i^2))/sqrt(nrow(out_ds)),
           observation_data = list(out_ds))
}