#' Initialize analysis
#'
#' @param country TODO
#' @param data TODO
#' @param pre_period_start TODO
#' @param pre_period_end TODO
#' @param post_period_start TODO
#' @param post_period_end TODO
#' @param eval_period_start TODO
#' @param eval_period_end TODO
#' @param n_seasons TODO
#' @param year_def TODO
#' @param group_name TODO
#' @param date_name TODO
#' @param outcome_name TODO
#' @param denom_name TODO
#' @return Initialized analysis object, `analysis` as described below
#'
#' `analysis$country` as passed in in `country`
#' `analysis$input_data` as passed in in `data`
#' `analysis$n_seasons` as passed in in `n_seasons`
#' `analysis$year_def` as passed in in `year_def`
#' `analysis$pre_period` TODO
#' `analysis$post_period` TODO
#' `analysis$eval_period` TODO
#' `analysis$start_date` TODO
#' `analysis$intervention_date` TODO
#' `analysis$end_date` TODO
#' `analysis$group_name` as passed in in `group_name`
#' `analysis$date_name` as passed in in `date_name`
#' `analysis$outcome_name` as passed in in `outcome_name`
#' `analysis$denom_name` as passed in in `denom_name`
#' `analysis$time_points` TODO
#' `analysis$groups` TODO
#' `analysis$sparse_groups` TODO
#' `analysis$model_size` TODO
#' `analysis$covars` TODO
#' `analysis$outcome` TODO
#'
#' @importFrom listenv listenv
#' @export

syncon.init <- function(country,
                        data,
                        pre_period_start,
                        pre_period_end,
                        post_period_start,
                        post_period_end,
                        eval_period_start,
                        eval_period_end,
                        n_seasons,
                        year_def,
                        group_name,
                        date_name,
                        outcome_name,
                        denom_name) {
  analysis = listenv(
    time_points = NA,
    
    groups = NA,
    sparse_groups = NA,
    model_size = NA,
    covars = NA,
    outcome = NA,
    
    results = list(
      impact = NA,
      crossval = NA,
      sensitivity = NA
    ),
    
    stacking_weights.all.m = NA,
    
    .private = listenv(
      # Variants
      variants = list(
        full = list(
          var.select.on = TRUE,
          trend = FALSE,
          name = "Synthetic controls"
        ),
        time = list(
          var.select.on = FALSE,
          trend = TRUE,
          name = "Time trend"
        ),
        time_no_offset = list(
          var.select.on = FALSE,
          trend = FALSE,
          name = "Time trend (no offset)"
        ),
        pca = list(
          var.select.on = FALSE,
          trend = FALSE,
          name = "STL+PCA"
        )
      ),
      
      exclude_covar = NA,
      exclude_group = NA,
      
      # Computation state
      data = list(),
      data.cv = list(),
      n_cores = NA,
      ds = NA
    )
  )
  
  analysis$country <- country #Country or region name.
  analysis$n_seasons <-
    n_seasons #Number of months (seasons) per year. 12 for monthly, 4 for quarterly, 3 for trimester data.
  analysis$year_def <-
    year_def #Can be cal_year to aggregate results by Jan-Dec; 'epi_year' to aggregate July-June
  
  #MOST DATES MUST BE IN FORMAT "YYYY-MM-01", exception is end of pre period, which is 1 day before end of post period
  analysis$pre_period <-
    as.Date(c(pre_period_start, pre_period_end)) #Range over which the data is trained for the CausalImpact model.
  analysis$start_date <- analysis$pre_period[1]
  analysis$post_period <-
    as.Date(c(post_period_start, post_period_end)) #Range from the intervention date to the end date.
  analysis$intervention_date <- analysis$post_period[1] - 1
  analysis$end_date <- analysis$post_period[2]
  
  analysis$eval_period <-
    as.Date(c(eval_period_start, eval_period_end)) #Range over which rate ratio calculation will be performed.
  
  analysis$group_name <-
    group_name #Name of column containing group labels.
  analysis$date_name <- date_name #Name of column containing dates.
  analysis$outcome_name <-
    outcome_name #Name of column containing outcome.
  analysis$denom_name <-
    denom_name #Name of column containing denominator to be used in offset.
  
  analysis$.private$exclude_covar <-
    c() #User-defined list of covariate columns to exclude from all analyses.
  analysis$.private$exclude_group <-
    c() #User-defined list of groups to exclude from analyses.
  
  #Assign variable values
  analysis$input_data <- data
  return(analysis)
}

#' Perform impact analysis
#'
#' @param analysis Analysis object, initialized by TODO.init.
#' @return Analysis results, `results`, as described below
#'
#' `results$full` TODO
#' `results$time` TODO
#' `results$time_no_offset` TODO
#' `results$pca` TODO
#' `results$its` TODO
#' `results$best` TODO
#' `results$point.weights` TODO
#' `results$rr_mean_combo` TODO
#'
#' @importFrom stats AIC as.formula cov dpois glm median poisson prcomp predict quantile rmultinom rnorm rpois sd setNames stl var vcov complete.cases
#' @importFrom loo stacking_weights
#' @importFrom lme4 glmer glmerControl fixef
#' @importFrom lubridate as_date %m+% year month quarter
#' @importFrom splines bs
#' @importFrom pomp logmeanexp
#' @importFrom reshape melt
#' @importFrom MASS mvrnorm
#' @importFrom RcppRoll roll_sum
#' @importFrom pogit poissonBvs
#' @importFrom parallel detectCores makeCluster clusterEvalQ clusterExport stopCluster
#' @importFrom pbapply pblapply
#' @export

syncon.impact = function(analysis) {
  syncon.impact.pre(analysis)
  results = list()
  
  #Start Cluster for CausalImpact (the main analysis function).
  cl <- makeCluster(analysis$.private$n_cores)
  clusterEvalQ(cl, {
    library(pogit, quietly = TRUE)
    library(lubridate, quietly = TRUE)
  })
  clusterExport(cl, c('doCausalImpact'), environment())
  
  for (variant in names(analysis$.private$variants)) {
    results[[variant]]$groups <- setNames(
      pblapply(
        cl = cl,
        analysis$.private$data[[variant]],
        FUN = doCausalImpact,
        analysis$intervention_date,
        analysis$n_seasons,
        var.select.on = analysis$.private$variants[[variant]]$var.select.on,
        time_points = analysis$time_points,
        trend = analysis$.private$variants[[variant]]$trend,
        crossval.stage = FALSE
      ),
      analysis$groups
    )
  }
  stopCluster(cl)
  
  for (variant in c('full', 'time')) {
    #Save the inclusion probabilities from each of the models
    results[[variant]]$inclusion_prob <-
      setNames(lapply(results[[variant]]$groups, inclusionProb), analysis$groups)
  }
  
  for (variant in names(analysis$.private$variants)) {
    #All model results combined
    results[[variant]]$quantiles <-
      setNames(lapply(
        analysis$groups,
        FUN = function(group) {
          rrPredQuantiles(
            impact = results[[variant]]$groups[[group]],
            denom_data = analysis$.private$ds[[group]][, analysis$denom_name],
            eval_period = analysis$eval_period,
            post_period = analysis$post_period,
            year_def = analysis$year_def,
            time_points = analysis$time_points,
            n_seasons = analysis$n_seasons
          )
        }
      ), analysis$groups)
  }
  
  # Calculate best model
  analysis$model_size <-
    sapply(results$full$groups, modelsize_func, n_seasons = analysis$n_seasons)
  results$best$quantiles <-
    vector("list", length(results$full$quantiles))
  results$best$quantiles[analysis$model_size >= 1] <-
    results$full$quantiles[analysis$model_size >= 1]
  results$best$quantiles[analysis$model_size < 1] <-
    results$pca$quantiles[analysis$model_size < 1]
  results$best$quantiles <-
    setNames(results$best$quantiles, analysis$groups)
  
  for (variant in c("best", names(analysis$.private$variants))) {
    # Predictions, aggregated by year
    results[[variant]]$pred_quantiles <-
      sapply(results[[variant]]$quantiles, getPred, simplify = 'array')
    results[[variant]]$ann_pred_quantiles <-
      sapply(results[[variant]]$quantiles, getAnnPred, simplify = FALSE)
  }
  
  for (variant in c('full', 'best')) {
    # Pointwise RR and uncertainty for second stage meta variant
    results[[variant]]$log_rr_quantiles <-
      sapply(
        results[[variant]]$quantiles,
        FUN = function(quantiles) {
          quantiles$log_rr_full_t_quantiles
        },
        simplify = 'array'
      )
    dimnames(results[[variant]]$log_rr_quantiles)[[1]] <-
      analysis$time_points
    results[[variant]]$log_rr_sd <-
      sapply(
        results[[variant]]$quantiles,
        FUN = function(quantiles) {
          quantiles$log_rr_full_t_sd
        },
        simplify = 'array'
      )
    results[[variant]]$log_rr_full_t_samples.prec <-
      sapply(
        results[[variant]]$quantiles,
        FUN = function(quantiles) {
          quantiles$log_rr_full_t_samples.prec
        },
        simplify = 'array'
      )
  }
  
  for (variant in c("best", names(analysis$.private$variants))) {
    # Rolling rate ratios
    results[[variant]]$rr_roll <-
      sapply(
        results[[variant]]$quantiles,
        FUN = function(quantiles) {
          quantiles$roll_rr
        },
        simplify = 'array'
      )
    # Rate ratios for evaluation period.
    results[[variant]]$rr_mean <-
      t(sapply(results[[variant]]$quantiles, getRR))
  }
  
  results$best$log_rr <- t(sapply(results$best$quantiles, getsdRR))
  
  for (variant in c("best", names(analysis$.private$variants))) {
    results[[variant]]$rr_mean_intervals <-
      setNames(
        data.frame(
          makeInterval(results[[variant]]$rr_mean[, 2], results[[variant]]$rr_mean[, 3], results[[variant]]$rr_mean[, 1]),
          check.names = FALSE,
          row.names = analysis$groups
        ),
        c(
          paste(analysis$.private$variants[[variant]]$name, 'Estimate (95% CI)')
        )
      )
  }
  
  colnames(results$time$rr_mean) <-
    paste('Time_trend', colnames(results$time$rr_mean))
  
  for (variant in c("best", names(analysis$.private$variants))) {
    results[[variant]]$cumsum_prevented <-
      sapply(
        analysis$groups,
        FUN = cumsum_func,
        quantiles = results[[variant]]$quantiles,
        outcome = analysis$outcome,
        analysis$time_points,
        analysis$post_period,
        simplify = 'array'
      )
  }
  
  #Run a classic ITS analysis
  rr.its1 <-
    lapply(
      analysis$.private$data$time,
      its_func,
      post_period = analysis$post_period,
      eval_period = analysis$eval_period,
      time_points = analysis$time_points
    )
  rr.t <- sapply(rr.its1, `[[`, "rr.q.t", simplify = 'array')
  results$its = list()
  results$its$rr_end <-
    t(sapply(rr.its1, `[[`, "rr.q.post", simplify = 'array'))
  results$its$rr_mean_intervals <-
    data.frame(
      'Classic ITS (95% CI)' = makeInterval(
        results$its$rr_end[, 2],
        results$its$rr_end[, 3],
        results$its$rr_end[, 1]
      ),
      check.names = FALSE,
      row.names = analysis$groups
    )
  
  #Combine RRs into 1 for ease of plotting
  results$rr_mean_combo <- as.data.frame(rbind(
    cbind(
      rep(1, nrow(results$full$rr_mean)),
      analysis$groups,
      seq(
        from = 1,
        by = 1,
        length.out = nrow(results$full$rr_mean)
      ),
      results$full$rr_mean
    ),
    cbind(
      rep(2, nrow(results$time$rr_mean)),
      analysis$groups,
      seq(
        from = 1,
        by = 1,
        length.out = nrow(results$time$rr_mean)
      ),
      results$time$rr_mean
    ),
    cbind(
      rep(3, nrow(results$time_no_offset$rr_mean)),
      analysis$groups,
      seq(
        from = 1,
        by = 1,
        length.out = nrow(results$time_no_offset$rr_mean)
      ),
      results$time_no_offset$rr_mean
    ),
    cbind(
      rep(4, nrow(results$pca$rr_mean)),
      analysis$groups,
      seq(
        from = 1,
        by = 1,
        length.out = nrow(results$pca$rr_mean)
      ),
      results$pca$rr_mean
    )
  ))
  
  results$point.weights <-
    as.data.frame(matrix(rep(1, nrow(
      results$rr_mean_combo
    )), ncol = 1))
  names(results$point.weights) <- 'value'
  
  names(results$rr_mean_combo) <-
    c('Model', 'groups', 'group.index', 'lcl', 'mean.rr', 'ucl')
  results$rr_mean_combo$group.index <-
    as.numeric(as.character(results$rr_mean_combo$group.index))
  results$rr_mean_combo$mean.rr <-
    as.numeric(as.character(results$rr_mean_combo$mean.rr))
  results$rr_mean_combo$lcl <-
    as.numeric(as.character(results$rr_mean_combo$lcl))
  results$rr_mean_combo$ucl <-
    as.numeric(as.character(results$rr_mean_combo$ucl))
  results$rr_mean_combo$group.index[results$rr_mean_combo$Model == 2] <-
    results$rr_mean_combo$group.index[results$rr_mean_combo$Model == 2] + 0.15
  results$rr_mean_combo$group.index[results$rr_mean_combo$Model == 3] <-
    results$rr_mean_combo$group.index[results$rr_mean_combo$Model == 3] + 0.3
  results$rr_mean_combo$group.index[results$rr_mean_combo$Model == 4] <-
    results$rr_mean_combo$group.index[results$rr_mean_combo$Model == 4] + 0.45
  results$rr_mean_combo$Model <-
    as.character(results$rr_mean_combo$Model)
  results$rr_mean_combo$Model[results$rr_mean_combo$Model == '1'] <-
    "Synthetic Controls"
  results$rr_mean_combo$Model[results$rr_mean_combo$Model == '2'] <-
    "Time trend"
  results$rr_mean_combo$Model[results$rr_mean_combo$Model == '3'] <-
    "Time trend (No offset)"
  results$rr_mean_combo$Model[results$rr_mean_combo$Model == '4'] <-
    "STL+PCA"
  results$rr_mean_combo$est.index <-
    as.factor(1:nrow(results$rr_mean_combo))
  #Fix order for axis
  results$rr_mean_combo$Model <-
    as.factor(results$rr_mean_combo$Model)
  results$rr_mean_combo$Model <-
    factor(results$rr_mean_combo$Model,
           levels(results$rr_mean_combo$Model)[c(2, 3, 4, 1)])
  #print(levels(rr_mean_combo$Model))
  
  
  analysis$results$impact <- results
  return(results)
}

#' Perform cross-validation
#'
#' @param analysis Analysis object, initialized by TODO.init. You must call TODO.impact before calling TODO.sensitivity
#' @return Cross-validation results, `results`, as described below
#'
#' `results$full` TODO
#' `results$time` TODO
#' `results$time_no_offset` TODO
#' `results$pca` TODO
#' `results$ann_pred_quantiles_stack` TODO
#' `results$cumsum_prevented_stack` TODO
#' `results$log_rr_quantiles_stack` TODO
#' `results$log_rr_samples.prec.post_stack` TODO
#' `results$point.weights` TODO
#' `results$pred_quantiles_stack` TODO
#' `results$quantiles_stack` TODO
#' `results$rr_mean_combo` TODO
#' `results$rr_mean_stack` TODO
#' `results$rr_mean_stack_intervals` TODO
#' `results$rr_roll_stack` TODO
#' `results$stacking_weights` TODO
#' `results$stacking_weights.all` TODO
#' `results$stacking_weights.all.m` TODO
#'
#' @export

syncon.crossval = function(analysis) {
  results = list()
  
  #Creates List of lists: 1 entry for each stratum; within this, there are CV datasets for each year left out, and within this, there are 2 lists, one with full dataset, and one with the CV dataset
  for (variant in names(analysis$.private$variants)) {
    analysis$.private$data.cv[[variant]] <-
      lapply(
        analysis$.private$data[[variant]],
        makeCV,
        analysis$time_points,
        analysis$intervention_date
      )
  }
  
  #Run the models on each of these datasets
  cl <- makeCluster(analysis$.private$n_cores)
  clusterEvalQ(cl, {
    library(pogit, quietly = TRUE)
    
    library(lubridate, quietly = TRUE)
  })
  clusterExport(cl, c('doCausalImpact'), environment())
  for (variant in names(analysis$.private$variants)) {
    results[[variant]]$groups <- setNames(
      pblapply(
        cl = cl,
        analysis$.private$data.cv[[variant]],
        FUN = function(x)
          lapply(
            x,
            doCausalImpact,
            analysis$intervention_date,
            analysis$n_seasons,
            time_points = analysis$time_points,
            crossval.stage = TRUE,
            var.select.on = analysis$.private$variants[[variant]]$var.select.on,
          )
      ),
      analysis$groups
    )
  }
  stopCluster(cl)
  
  ll.cv = list()
  
  #Calculate pointwise log likelihood for cross-val prediction sample vs observed
  #These are N_iter*N_obs*N_cross_val array
  for (variant in names(analysis$.private$variants)) {
    ll.cv[[variant]] <-
      lapply(results[[variant]]$groups, function(x)
        lapply(x, crossval.log.lik))
    ll.cv[[variant]] <- lapply(ll.cv[[variant]], reshape.arr)
  }
  
  #Create list that has model result for each stratum
  ll.compare <- vector("list", length(ll.cv$pca))
  results$stacking_weights.all <-
    matrix(NA, nrow = length(ll.cv$pca), ncol = 4)
  
  for (i in 1:length(ll.compare)) {
    #will get NAs if one of covariates is constant in fitting period (ie pandemic flu dummy)...should fix this above
    ll.compare[[i]] <-
      cbind(ll.cv$full[[i]],
            ll.cv$time_no_offset[[i]],
            ll.cv$time[[i]],
            ll.cv$pca[[i]])
    keep <- complete.cases(ll.compare[[i]])
    ll.compare[[i]] <- ll.compare[[i]][keep, ]
    #occasionally if there is a very poor fit, likelihood is very very small, which leads to underflow issue and log(0)...delete these rows to avoid this as a dirty solution. Better would be to fix underflow
    row.min <- apply(exp(ll.compare[[i]]), 1, min)
    ll.compare[[i]] <- ll.compare[[i]][!(row.min == 0), ]
    #if(min(exp(ll.compare[[i]]))>0){
    results$stacking_weights.all[i, ] <-
      stacking_weights(ll.compare[[i]])
    #}
  }
  results$stacking_weights.all <-
    as.data.frame(round(results$stacking_weights.all, 3))
  names(results$stacking_weights.all) <-
    lapply(analysis$.private$variants, function(v) {
      v$name
    })
  results$stacking_weights.all <-
    cbind.data.frame(data.frame(groups = analysis$groups),
                     results$stacking_weights.all)
  results$stacking_weights.all.m <-
    melt(results$stacking_weights.all, id.vars = 'groups')
  # results$stacking_weights.all.m<-results$stacking_weights.all.m[order(results$stacking_weights.all.m$groups),]
  
  stacked.ests <- mapply(
    FUN = stack.mean,
    group = analysis$groups,
    impact_full = analysis$results$impact$full$groups,
    impact_time = analysis$results$impact$time$groups,
    impact_time_no_offset = analysis$results$impact$time_no_offset$groups,
    impact_pca = analysis$results$impact$pca$groups,
    MoreArgs = list(
      stacking_weights.all = results$stacking_weights.all,
      outcome = analysis$outcome
    ),
    SIMPLIFY = FALSE
  )
  # plot.stacked.ests<-lapply(stacked.ests,plot.stack.est)
  results$quantiles_stack <-
    setNames(lapply(
      analysis$groups,
      FUN = function(group) {
        rrPredQuantiles(
          impact = stacked.ests[[group]],
          denom_data = analysis$.private$ds[[group]][, analysis$denom_name],
          analysis$eval_period,
          analysis$post_period,
          analysis$n_seasons,
          analysis$year_def,
          analysis$time_points
        )
      }
    ), analysis$groups)
  results$pred_quantiles_stack <-
    sapply(results$quantiles_stack, getPred, simplify = 'array')
  results$rr_roll_stack <-
    sapply(
      results$quantiles_stack,
      FUN = function(quantiles_stack) {
        quantiles_stack$roll_rr
      },
      simplify = 'array'
    )
  results$rr_mean_stack <-
    round(t(sapply(results$quantiles_stack, getRR)), 2)
  results$rr_mean_stack_intervals <-
    data.frame(
      'Stacking Estimate (95% CI)' = makeInterval(
        results$rr_mean_stack[, 2],
        results$rr_mean_stack[, 3],
        results$rr_mean_stack[, 1]
      ),
      check.names = FALSE,
      row.names = analysis$groups
    )
  results$cumsum_prevented_stack <-
    sapply(
      analysis$groups,
      FUN = cumsum_func,
      quantiles = results$quantiles_stack,
      outcome = analysis$outcome,
      analysis$time_points,
      analysis$post_period,
      simplify = 'array'
    )
  results$ann_pred_quantiles_stack <-
    sapply(results$quantiles_stack, getAnnPred, simplify = FALSE)
  #Preds: Compare observed and expected
  results$full$pred <-
    lapply(results$impact$full, function(x)
      sapply(x, pred.cv, simplify = 'array'))
  results$pca$pred <-
    lapply(results$impact$pca, function(x)
      sapply(x, pred.cv, simplify = 'array'))
  
  results$log_rr_quantiles_stack <-
    sapply(
      results$quantiles_stack,
      FUN = function(quantiles) {
        quantiles$log_rr_full_t_quantiles
      },
      simplify = 'array'
    )
  dimnames(results$log_rr_quantiles_stack)[[1]] <-
    analysis$time_points
  
  results$log_rr_samples.prec.post_stack <-
    sapply(
      results$quantiles_stack,
      FUN = function(quantiles) {
        quantiles$log_rr_full_t_samples.prec.post
      },
      simplify = 'array'
    )
  
  results$rr_mean_combo = analysis$results$impact$rr_mean_combo
  results$point.weights <- results$stacking_weights.all.m
  
  analysis$results$crossval <- results
  return(results)
}

#' Perform sensitivity analysis
#'
#' @param analysis Analysis object, initialized by TODO.init. You must call TODO.impact before calling TODO.sensitivity
#' @return Sensitivity analysis results, `results`, as described below
#'
#' `results$rr_table` TODO
#' `results$rr_table_intervals` TODO
#' `results$sensitivity_pred_quantiles` TODO
#' `results$sensitivity_table` TODO
#' `results$sensitivity_table_intervals` TODO
#'
#' @export

syncon.sensitivity = function(analysis) {
  results = list()
  bad_sensitivity_groups <-
    sapply(analysis$covars$full, function (covar) {
      ncol(covar) <= analysis$n_seasons - 1 + 3
    })
  sensitivity_covars_full <-
    analysis$covars$full[!bad_sensitivity_groups]
  sensitivity_ds <- analysis$.private$ds[!bad_sensitivity_groups]
  sensitivity_impact_full <-
    analysis$results$impact$full$groups[!bad_sensitivity_groups]
  sensitivity_groups <- analysis$groups[!bad_sensitivity_groups]
  
  if (length(sensitivity_groups) != 0) {
    #Weight Sensitivity Analysis - top weighted variables are excluded and analysis is re-run.
    cl <- makeCluster(analysis$.private$n_cores)
    clusterEvalQ(cl, {
      library(pogit, quietly = TRUE)
      library(lubridate, quietly = TRUE)
      library(RcppRoll, quietly = TRUE)
    })
    clusterExport(
      cl,
      c(
        'sensitivity_ds',
        'weightSensitivityAnalysis',
        'sensitivity_groups'
      ),
      environment()
    )
    sensitivity_analysis_full <-
      setNames(
        pblapply(
          cl = cl,
          sensitivity_groups,
          FUN = weightSensitivityAnalysis,
          covars = sensitivity_covars_full,
          ds = sensitivity_ds,
          impact = sensitivity_impact_full,
          time_points = analysis$time_points,
          intervention_date = analysis$intervention_date,
          n_seasons = analysis$n_seasons,
          outcome = analysis$outcome,
          eval_period = analysis$eval_period,
          post_period = analysis$post_period,
          year_def = analysis$year_def
        ),
        sensitivity_groups
      )
    stopCluster(cl)
    
    results$sensitivity_pred_quantiles <-
      lapply(
        sensitivity_analysis_full,
        FUN = function(sensitivity_analysis) {
          pred_list <-
            vector(mode = 'list',
                   length = length(sensitivity_analysis))
          for (sensitivity_index in 1:length(sensitivity_analysis)) {
            pred_list[[sensitivity_index]] <-
              getPred(sensitivity_analysis[[sensitivity_index]])
          }
          return(pred_list)
        }
      )
    
    #Table of rate ratios for each sensitivity analysis level
    results$sensitivity_table <-
      t(
        sapply(
          sensitivity_groups,
          sensitivityTable,
          sensitivity_analysis = sensitivity_analysis_full,
          original_rr = analysis$results$impact$full$rr_mean
        )
      )
    results$sensitivity_table_intervals <- data.frame(
      'Estimate (95% CI)' = makeInterval(
        results$sensitivity_table[, 2],
        results$sensitivity_table[, 3],
        results$sensitivity_table[, 1]
      ),
      'Top Control 1' = results$sensitivity_table[, 'Top Control 1'],
      'Inclusion Probability of Control 1' = results$sensitivity_table[, 'Inclusion Probability of Control 1'],
      'Control 1 Estimate (95% CI)' = makeInterval(
        results$sensitivity_table[, 7],
        results$sensitivity_table[, 8],
        results$sensitivity_table[, 6]
      ),
      'Top Control 2' = results$sensitivity_table[, 'Top Control 2'],
      'Inclusion Probability of Control 2' = results$sensitivity_table[, 'Inclusion Probability of Control 2'],
      'Control 2 Estimate (95% CI)' = makeInterval(
        results$sensitivity_table[, 12],
        results$sensitivity_table[, 13],
        results$sensitivity_table[, 11]
      ),
      'Top Control 3' = results$sensitivity_table[, 'Top Control 3'],
      'Inclusion Probability of Control 3' = results$sensitivity_table[, 'Inclusion Probability of Control 3'],
      'Control 3 Estimate (95% CI)' = makeInterval(
        results$sensitivity_table[, 17],
        results$sensitivity_table[, 18],
        results$sensitivity_table[, 16]
      ),
      check.names = FALSE
    )
    results$rr_table <-
      cbind.data.frame(round(analysis$results$impact$time$rr_mean[!bad_sensitivity_groups,], 2),
                       results$sensitivity_table)
    results$rr_table_intervals <-
      cbind(
        'Trend Estimate (95% CI)' = analysis$results$impact$time$rr_mean_intervals[!bad_sensitivity_groups,],
        results$sensitivity_table_intervals
      )
  } else {
    results$sensitivity_table_intervals <- NA
  }
  
  analysis$results$sensitivity <- results
  return(results)
}

syncon.impact.pre = function(analysis) {
  # Setup data
  prelog_data <-
    analysis$input_data[!is.na(analysis$input_data[, analysis$outcome_name]), ]#If outcome is missing, delete
  prelog_data[, analysis$group_name] = prelog_data[, analysis$group_name] %% 2
  analysis$groups <-
    as.character(unique(unlist(prelog_data[, analysis$group_name], use.names = FALSE)))
  analysis$groups <-
    analysis$groups[!(analysis$groups %in% analysis$.private$exclude_group)]
  
  # Format covars
  prelog_data[, analysis$date_name] <-
    as.Date(as.character(prelog_data[, analysis$date_name]),
            tryFormats = c("%m/%d/%Y", '%Y-%m-%d'))
  
  #test<-split(prelog_data, factor(prelog_data[,analysis$group_name]))
  #outcome.na<-sapply(test, function(x) sum(is.na(x[,analysis$outcome_name])))
  prelog_data[, analysis$date_name] <-
    formatDate(prelog_data[, analysis$date_name])
  prelog_data <- setNames(
    lapply(
      analysis$groups,
      FUN = splitGroup,
      ungrouped_data = prelog_data,
      group_name = analysis$group_name,
      date_name = analysis$date_name,
      start_date = analysis$start_date,
      end_date = analysis$end_date,
      no_filter = c(
        analysis$group_name,
        analysis$date_name,
        analysis$outcome_name,
        analysis$denom_name
      )
    ),
    analysis$groups
  )
  #if (exists('exclude_group')) {prelog_data <- prelog_data[!(names(prelog_data) %in% exclude_group)]}
  
  #Log-transform all variables, adding 0.5 to counts of 0.
  analysis$.private$ds <-
    setNames(lapply(
      prelog_data,
      FUN = logTransform,
      no_log = c(
        analysis$group_name,
        analysis$date_name,
        analysis$outcome_name
      )
    ),
    analysis$groups)
  analysis$time_points <-
    unique(analysis$.private$ds[[1]][, analysis$date_name])
  
  #Monthly dummies
  if (analysis$n_seasons == 4) {
    dt <- quarter(as.Date(analysis$time_points))
  }
  if (analysis$n_seasons == 12) {
    dt <- month(as.Date(analysis$time_points))
  }
  if (analysis$n_seasons == 3) {
    dt.m <- month(as.Date(analysis$time_points))
    dt <- dt.m
    dt[dt.m %in% c(1, 2, 3, 4)] <- 1
    dt[dt.m %in% c(5, 6, 7, 8)] <- 2
    dt[dt.m %in% c(9, 10, 11, 12)] <- 3
  }
  season.dummies <- dummies::dummy(dt)
  season.dummies <- as.data.frame(season.dummies)
  names(season.dummies) <- paste0('s', 1:analysis$n_seasons)
  season.dummies <- season.dummies[, -analysis$n_seasons]
  
  analysis$.private$ds <-
    lapply(analysis$.private$ds, function(ds) {
      if (!(analysis$denom_name %in% colnames(ds))) {
        ds[analysis$denom_name] <- 0
      }
      return(ds)
    })
  
  analysis$sparse_groups <-
    sapply(analysis$.private$ds, function(ds) {
      return(ncol(ds[!(
        colnames(ds) %in% c(
          analysis$date_name,
          analysis$group_name,
          analysis$denom_name,
          analysis$outcome_name,
          analysis$.private$exclude_covar
        )
      )]) == 0)
    })
  analysis$.private$ds <-
    analysis$.private$ds[!analysis$sparse_groups]
  analysis$groups <- analysis$groups[!analysis$sparse_groups]
  
  #Process and standardize the covariates. For the Brazil data, adjust for 2008 coding change.
  analysis$covars = list()
  analysis$covars$full <-
    setNames(lapply(analysis$.private$ds, function(group) {
      makeCovars(
        analysis$country,
        analysis$time_points,
        analysis$intervention_date,
        season.dummies,
        group
      )
    }), analysis$groups)
  analysis$covars$full <-
    lapply(
      analysis$covars$full,
      FUN = function(covars) {
        covars[,!(colnames(covars) %in% analysis$.private$exclude_covar), drop = FALSE]
      }
    )
  analysis$covars$time <-
    setNames(lapply(
      analysis$covars$full,
      FUN = function(covars) {
        as.data.frame(list(cbind(
          season.dummies, time_index = 1:nrow(covars)
        )))
      }
    ),
    analysis$groups)
  analysis$covars$null <-
    setNames(lapply(
      analysis$covars$full,
      FUN = function(covars) {
        as.data.frame(list(cbind(season.dummies)))
      }
    ),
    analysis$groups)
  
  #Standardize the outcome variable and save the original mean and SD for later analysis.
  analysis$outcome <-
    sapply(
      analysis$.private$ds,
      FUN = function(data) {
        data[, analysis$outcome_name]
      }
    )
  offset <-
    sapply(
      analysis$.private$ds,
      FUN = function(data)
        exp(data[, analysis$denom_name])
    ) #offset term on original scale; 1 column per age group
  
  ##SECTION 1: CREATING SMOOTHED VERSIONS OF CONTROL TIME SERIES AND APPENDING THEM ONTO ORIGINAL DATAFRAME OF CONTROLS
  #EXTRACT LONG TERM TREND WITH DIFFERENT LEVELS OF SMOOTHNESS USING STL
  # Set a list of parameters for STL
  stl.covars <-
    mapply(
      smooth_func,
      ds.list = analysis$.private$ds,
      covar.list = analysis$covars$full,
      SIMPLIFY = FALSE,
      MoreArgs = list(n_seasons = analysis$n_seasons)
    )
  post.start.index <-
    which(analysis$time_points == analysis$post_period[1])
  
  if (length(analysis$groups) > 1) {
    stl.data.setup <-
      mapply(
        stl_data_fun,
        covars = stl.covars,
        ds.sub = analysis$.private$ds ,
        SIMPLIFY = FALSE,
        MoreArgs = list(
          n_seasons = analysis$n_seasons,
          outcome_name = analysis$outcome_name,
          post.start.index = post.start.index
        )
      ) #list of lists that has covariates for each regression for each strata
  } else{
    stl.data.setup <-
      list(
        mapply(
          stl_data_fun,
          covars = stl.covars,
          ds.sub = analysis$.private$ds,
          MoreArgs = list(
            n_seasons = analysis$n_seasons,
            outcome_name = analysis$outcome_name,
            post.start.index = post.start.index
          )
        )
      )
  }
  
  ##SECTION 2: run first stage models
  analysis$.private$n_cores <- detectCores() - 1
  glm.results <-
    vector("list", length = length(stl.data.setup)) #combine models into a list
  cl <- makeCluster(analysis$.private$n_cores)
  clusterEvalQ(cl, {
    library(lme4, quietly = TRUE)
  })
  clusterExport(cl,
                c('stl.data.setup', 'glm.fun', 'post.start.index'),
                environment())
  for (i in 1:length(stl.data.setup)) {
    glm.results[[i]] <-
      pblapply(
        cl = cl,
        stl.data.setup[[i]],
        FUN = function(d) {
          glm.fun(d, post.start.index)
        }
      )
  }
  stopCluster(cl)
  ######################
  
  # Combine data
  #Combine the outcome, covariates, and time point information.
  analysis$.private$data$full <-
    setNames(
      lapply(
        analysis$groups,
        makeTimeSeries,
        outcome = analysis$outcome,
        covars = analysis$covars$full
      ),
      analysis$groups
    )
  analysis$.private$data$time <-
    setNames(
      lapply(
        analysis$groups,
        makeTimeSeries,
        outcome = analysis$outcome,
        covars = analysis$covars$time,
        trend = TRUE,
        offset = offset
      ),
      analysis$groups
    )
  analysis$.private$data$pca <-
    mapply(
      FUN = pca_top_var,
      glm.results.in = glm.results,
      covars = stl.covars,
      ds.in = analysis$.private$ds,
      SIMPLIFY = FALSE,
      MoreArgs = list(
        outcome_name = analysis$outcome_name,
        season.dummies = season.dummies
      )
    )
  names(analysis$.private$data$pca) <- analysis$groups
  #Time trend model but without a denominator
  analysis$.private$data$time_no_offset <-
    setNames(
      lapply(
        analysis$groups,
        makeTimeSeries,
        outcome = analysis$outcome,
        covars = analysis$covars$time,
        trend = FALSE
      ),
      analysis$groups
    )
}
