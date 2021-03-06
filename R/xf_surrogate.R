#'A function for ...
#'
#'
#'@param ds a \code{data.frame}.
#'@param x names any other covariates (eg. age, sex, etc). Default is \code{NULL}.
#'@param s names surrogates
#'@param y names outcome
#'@param a treatment variable name (eg. groups). Expect a binary variable made of \code{1}s and \code{0}s.
#'@param K number of folds for cross validation. Default is \code{5}
#'@param outcome_learners Default is \code{NULL}
#'@param ps_learners only used for the superlearner
#'@param interaction_model logical indicating wether an interaction model should be considered.
#'Default is \code{TRUE}
#'@param trim_at Default is \code{0.05}
#'@param outcome_family Default is \code{'gaussian'}. Other choice is \code{'binomial'} for binary outcome.
#'@param mthd Regression method. Default is \code{'superlearner'}, other choice
#'is \code{'lasso'}.
#'@param n_ptb Number of perturbations. Default is \code{0} which means asymptotics
#'@param ... additional parameters (in particular for super_learner)
#'
#'@importFrom purrr map
#'
#'@export
xf_surrogate <- function(ds,
                         x = NULL,
                         s,
                         y,
                         a,
                         K = 5,
                         outcome_learners = NULL,
                         ps_learners = outcome_learners,
                         interaction_model = TRUE,
                         trim_at = 0.05,
                         outcome_family = gaussian(),
                         mthd = 'superlearner',
                         n_ptb = 0,
                         ncores = parallel::detectCores()-1,
                         ...) {

  #sanity checks
  if(!is.null(x)){
    if(sum(is.na(ds[,x]))>1){
      stop("no missing values allowed in 'x'")
    }
    isfact <- sapply(ds[, x], is.factor)
    if(sum(isfact) > 0 | sum(sapply(ds[, x], is.character))>0){
      stop("only numeric covariates allowed in 'x'. Please consider using model.matrix() beforehand...")
    }
    # if(sum(isfact>1)){
    #   newx <- as.matrix(model.matrix(as.formula(paste0(c("~", all_of(x)[isfact]), collapse = " + ")), data=ds)[,-1, drop=FALSE])
    #   temp <- ds %>% select(-all_of(x)[isfact])
    #     mutate(newx, after = x[!isfact][length(x[!isfact])])
    #
    #   x <- x[!isfact]
    #   x <- append(x, colnames(newx))
    # }
  }
  if(sum(sapply(ds[, s], is.factor))>0 | sum(sapply(ds[, s], is.character))>0){
    stop("only numeric surrogate allowed in 's'")
  }
  if(sum(is.na(ds[,s]))>1){
    stop("no missing values allowed in 's'")
  }

  if(any(!(unlist(ds[, a]) %in% c(0,1)))){
    stop("Treatment 'a' should only contain 0s and 1s")
  }
  if(sum(is.na(ds[,a]))>1){
    stop("no missing values allowed in 'a'")
  }
  if(sum(is.na(ds[,y]))>1){
    stop("no missing values allowed in 'y'")
  }

  n <- nrow(ds)

  if (is.null(x)) {
    delta_s_fit <- xfit_dr(ds = ds,
                           x = s,
                           y = y,
                           a = a,
                           K = K,
                           outcome_learners = outcome_learners,
                           ps_learners = ps_learners,
                           interaction_model = interaction_model,
                           trim_at = trim_at,
                           outcome_family = outcome_family,
                           mthd = mthd,
                           ncores = ncores, ...)

    n1 <- sum(ds %>% pull(!!sym(a)))
    n0 <- sum( 1 - ds %>% pull(!!sym(a)))
    u1 <- ds %>%
      mutate(u_i = n/n1*!!sym(a)*!!sym(y) - n/n0*(1-!!sym(a))*!!sym(y)) %>%
      pull(u_i)
    deltahat <- mean(u1)
  } else {
    delta_s_fit <- xfit_dr(ds = ds,
                           x = c(x, s),
                           y = y,
                           a = a,
                           K = K,
                           outcome_learners = outcome_learners,
                           ps_learners = ps_learners,
                           interaction_model = interaction_model,
                           trim_at = trim_at,
                           outcome_family = outcome_family,
                           mthd = mthd,
                           ncores = ncores, ...)
    delta_fit <- xfit_dr(ds = ds,
                         x = x,
                         y = y,
                         a = a,
                         K = K,
                         outcome_learners = outcome_learners,
                         ps_learners = ps_learners,
                         interaction_model = interaction_model,
                         trim_at = trim_at,
                         outcome_family = outcome_family,
                         mthd = mthd,
                         ncores = ncores, ...)
    deltahat <- delta_fit$estimate
    u1 <- delta_fit$observation_data[[1]]$u_i
  }

  u2 <- delta_s_fit$observation_data[[1]]$u_i
  deltahat_s <- delta_s_fit$estimate

  w_o <- delta_s_fit$observation_data[[1]] %>%
    mutate(theta = 1*(pi > trim_at & pi < 1 - trim_at)) %>%
    pull(theta)
  deltahat_s_o <- mean(w_o*u2)

  if (n_ptb > 0) {
    g_ptb <- purrr::map(1:n_ptb, function(i) sqrt(12)*rbeta(n, shape1 = 1,
                                                            shape2 = 1) - sqrt(12)/2 + 1)
    ptb_ds <- purrr::map(g_ptb, function(g) {
      deltahat_g <- mean(u1*g)
      deltahat_sg <- mean(u2*g)
      R_g <- 1 - deltahat_sg/deltahat_g
      return(tibble(
        R_g,
        deltahat_sg,
        deltahat_g
      ))
    }) %>%
      bind_rows()
    ptb_out <- ptb_ds %>%
      summarise(R_qci_l = quantile(R_g, 0.025),
                R_qci_h = quantile(R_g, 0.975),
                R_ptb_se = sd(R_g)) %>%
      mutate(ptb_ds = list(ptb_ds))
  }

  sigmasq <- mean(u1^2/deltahat^2 + u2^2*deltahat_s^2/deltahat^4 - 2*u1*u2*deltahat_s/deltahat^3)
  sigmasq_o <- mean(u1^2/deltahat^2 + (w_o*u2)^2*deltahat_s^2/deltahat^4 - 2*w_o*u1*u2*deltahat_s/deltahat^3)
  sigmasq_diff <- mean(u1^2 + u2^2 - 2*u1*u2)
  out <- tibble(
    R = 1 - deltahat_s/deltahat,
    R_se = sqrt(sigmasq/length(u1)),
    deltahat_s,
    deltahat_s_se = sqrt(mean(u2^2)/length(u2)),
    pi_o = mean(w_o),
    R_o = 1 - deltahat_s_o/deltahat,
    R_o_se = sqrt(sigmasq_o/length(u1)),
    deltahat_s_o,
    deltahat_s_se_o = sqrt(mean((w_o*u2)^2)/length(u2)),
    deltahat,
    deltahat_se = sqrt(mean(u1^2)/length(u1)),
    delta_diff = deltahat - deltahat_s,
    dd_se = sqrt(sigmasq_diff/length(u1))
  )
  if (n_ptb > 0) {
    out <- out %>%
      full_join(ptb_out, by = character())
  }
  return(out)
}
