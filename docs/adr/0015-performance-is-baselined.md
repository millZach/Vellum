# Performance is baselined: work counts are budgets, timings are compared

Zach, on 2026-11-01: "One thing you really need to prioritize is how fast the application feels and how smooth it is to use", and "make sure any performance improvements are baselined as well, so if we see regressions we can refer to fast baselines." A speed-up nobody measures is lost to the next change that undoes it, and nobody notices until the Duo stutters.

We considered timing everything in CI and failing the build on a slow run, but GitHub's hosted macOS runners are shared and their timings move by tens of percent from run to run, so a failing timing would be noise more often than a regression. We considered device-only measurement, but nothing on the Duo runs on every pull request. We chose two kinds of metric:

- **Work counts are budgets, enforced.** Deterministic counts of work: paths rebuilt per redraw, points inspected per eraser sample, requests per action, bytes written per stroke. VellumCore tests measure them on made-up fixtures, on Forge's Linux Swift and in CI, and fail when one exceeds its baseline. A count does not depend on the machine, so it can fail a build fairly.
- **Timings are recorded and compared, never enforced.** Frame times, append and reopen times, and the like are measured in CI on every run, kept in the job log and an artifact, and compared with the baseline; one more than its tolerance worse raises a GitHub warning annotation, which the PR must explain.

## Consequences

- Each area keeps its numbers in one file, `docs/perf/baselines/<area>.json`, so lanes working on different areas never conflict. The budget tests read their file, so it is the single source of each number. `docs/perf/README.md` says how.
- **Budgets only tighten.** A change that makes a count smaller lowers its baseline in the same PR. Raising one needs its reason in the PR and in the entry's `note`.
- Every PR that touches drawing, storage, sync or the network reports before and after for its area in the PR body (AGENTS.md, "Speed is the product").
- Each timing baseline says where it was measured (runner image, Xcode, simulator runtime). Simulator timings are indicative; the Duo is the judge of how the app feels.

## Amended by #32

The first rule compared one run with one number at 25%, and the Release canvas timings warned on most runs: hosted runners' speed runs continuously across a range of about two to one and moves within a job. The Release canvas timings are now scaled by a speed probe, fixed work with no Vellum code in it, measured in the same run; the Release job takes the median of three launches; Release p50 warns at 25% worse, Release p95 at 40% and Debug p50 at 25%, and the rest only record. We did not classify runs as fast or slow, because 24 runs did not fall into two classes, and we did not compare with the slowest runs' numbers alone, because a 50% slowdown on a faster runner would then pass unseen. `docs/perf/README.md` has the rule and its measured false-warning rate.
