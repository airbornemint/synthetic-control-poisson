% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/analysis.R
\name{syncon.init}
\alias{syncon.init}
\title{Initialize analysis}
\usage{
syncon.init(country, data, pre_period_start, pre_period_end,
  post_period_start, post_period_end, eval_period_start, eval_period_end,
  n_seasons, year_def, group_name, date_name, outcome_name, denom_name)
}
\arguments{
\item{country}{TODO}

\item{data}{TODO}

\item{pre_period_start}{TODO}

\item{pre_period_end}{TODO}

\item{post_period_start}{TODO}

\item{post_period_end}{TODO}

\item{eval_period_start}{TODO}

\item{eval_period_end}{TODO}

\item{n_seasons}{TODO}

\item{year_def}{TODO}

\item{group_name}{TODO}

\item{date_name}{TODO}

\item{outcome_name}{TODO}

\item{denom_name}{TODO}
}
\value{
Initialized analysis object, `analysis` as described below

`analysis$country` as passed in in `country`
`analysis$input_data` as passed in in `data`
`analysis$n_seasons` as passed in in `n_seasons`
`analysis$year_def` as passed in in `year_def`
`analysis$pre_period` TODO
`analysis$post_period` TODO
`analysis$eval_period` TODO
`analysis$start_date` TODO
`analysis$intervention_date` TODO
`analysis$end_date` TODO
`analysis$group_name` as passed in in `group_name`
`analysis$date_name` as passed in in `date_name`
`analysis$outcome_name` as passed in in `outcome_name`
`analysis$denom_name` as passed in in `denom_name`
`analysis$time_points` TODO
`analysis$groups` TODO
`analysis$sparse_groups` TODO
`analysis$model_size` TODO
`analysis$covars` TODO
`analysis$outcome` TODO
}
\description{
Initialize analysis
}
