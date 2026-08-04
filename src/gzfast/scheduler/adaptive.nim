## Conservative worker-target heuristics used before empirical calibration.

import std/math

proc initialWorkerTarget*(maximum: int; availableWork = high(int)): int =
  ## Small budgets use their full allowance. Larger automatic budgets use
  ## the upstream-proven `ceil(2 * sqrt(maximum))` bootstrap and never create
  ## more workers than immediately visible work.
  if maximum <= 0 or availableWork <= 0: return 0
  let bootstrap = if maximum <= 4: maximum
                  else: int(ceil(2.0 * sqrt(float(maximum))))
  min(min(maximum, bootstrap), availableWork)
