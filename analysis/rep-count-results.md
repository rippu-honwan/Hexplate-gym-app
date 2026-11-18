# Rep counting from wrist motion: results (Stage D)

Data to 2026-11-18: 152 set recordings from an Apple Watch Series 9 (50 Hz), 85 joined to a
logged set. The logged reps are the label. Sets that `motion_check.py` flags are left out:
gaps, no movement, clipped, and since this round **under 1.5 or over 12 s per logged rep**
(the window missed the set, or ran on long after it). 65 sets from 6 workouts and 19 exercises
remain.

Evaluation is leave-one-workout-out: the grid point that does best on the other five workouts
counts this one. Splitting by workout, not by window or set, keeps a workout's own habits out
of its own score. Run `python3 analysis/rep_count.py`.

| Method (held out) | MAE | Exact | Within 1 |
|---|---|---|---|
| **peaks** (chosen) | **1.48** | **22/65 (34%)** | **36/65 (55%)** |
| always 10 reps (median) | 1.92 | 19/65 (29%) | 25/65 (38%) |
| watch live count (56 sets it counted) | 1.93 | 11/56 (20%) | 29/56 (52%) |
| acf | 2.37 | 10/65 (15%) | 24/65 (37%) |
| auto | 2.54 | 12/65 (18%) | 28/65 (43%) |
| span | 4.23 | 3/65 (5%) | 15/65 (23%) |

**peaks:** userAccel, band-pass 0.1-0.8 Hz (2nd-order Butterworth high-pass then low-pass, run
forward and backward over a 3 s odd reflection); each axis
clipped at 2x its 90th percentile of |x|; projected on the main axis (PCA). Then peaks and
troughs at least 1.25 s apart that stand out by 0.7 (or 0.8) of the 5-95 percentile range,
averaged. The workouts all picked accel and 0.7-0.8.

Ported to the watch as `WatchCore/SetRepCount.swift`. Its tests check the Swift counts and
signal against this script's output, on the committed fixtures and (locally, see the test)
on all 65 sets: identical counts.

## What failed, and why

- **Plain peak counting before the data fix:** MAE 2.81, worse than always guessing 9. Most of
  the error was 7 files whose window held almost none of the set (0.1-0.7 s per rep) or ran
  2-3 minutes past it. That is a recording problem, now a quality flag, not a counting one.
- **Unclipped signals:** grabbing and letting go of the handle swings 5-10x harder than a rep.
  It set the PCA axis and the scale, so the reps between fell under the threshold
  (a seated row with 16 clean accel cycles counted 3). Clipping took MAE from 1.89 to 1.37.
- **scipy's band-pass vs the portable one:** `sosfiltfilt(butter(2, [0.1, 0.8]))` scored 1.37;
  the plain biquads the watch can run score 1.48 (about one rep in seven sets). Kept the
  portable one rather than port scipy's filter design and padding.
- **A bigger grid overfits:** band edges x 6 prominences x 3 signals scored 1.20 on all data
  but 1.91 held out. With 65 sets the grid has to stay small.
- **Autocorrelation period (acf, span, auto):** the period estimate is often a half or a
  double period, and setup motion repeats too. Every method built on it scored worse than
  the constant guess.

## Caveats

- The clip factor (2.0) was chosen after looking at plots, not inside the cross-validation
  (with scipy's filter, 1.5 gave 1.35 and 3.0 gave 1.66).
- The first peak out of stillness stands only half as tall, so a clean synthetic set of 10 counts
  9. Real sets show no such bias (mean error +0.05).
- This counts a finished set from the whole window. The watch's live count works sample by
  sample, so the two numbers are not the same task. Stage E can use this one to fill in reps
  when the set ends.
- 19 exercises, most with 1-3 sets: per-exercise numbers mean little yet. The worst cases are
  dips and face pulls, where the wrist barely moves relative to the body.
- One lifter, one watch, left wrist.
