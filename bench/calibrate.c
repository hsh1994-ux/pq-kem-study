/*
 * calibrate -- once-per-run timer calibration for E1.
 *
 * Prints one line:  ns_per_tick=<f> tick_mhz=<f> core_ghz=<f>
 *
 * run_e1.py runs this once (after a warm-up, on the pinned core) and passes
 * ns_per_tick to every benchmark process in PQ_NS_PER_TICK, so all rows of
 * one run share the same tick-to-nanosecond conversion. It is also recorded
 * in the results header, with the core-clock estimate.
 */
#include <stdio.h>

#include "../common/cpucycles.h"

int main(void) {
    pq_spin_ms(200);
    double npt = cpucycles_ns_per_tick();
    printf("ns_per_tick=%.6f tick_mhz=%.3f core_ghz=%.3f\n", npt, 1e3 / npt, pq_core_ghz());
    return 0;
}
