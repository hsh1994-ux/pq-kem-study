/*
 * dudect_run.h -- shared driver loop for the E3 dudect harnesses.
 *
 * Each harness defines do_one_computation() and prepare_inputs() (the
 * dudect API) and calls dudect_run(). It keeps feeding batches until
 * leakage is found or the time budget runs out, then prints one line:
 *
 *   RESULT,<tier>,<target>,<op>,<timer>,<measurements>,<max_t>,<verdict>,<seconds>
 *
 * verdict: leak          |t| > 10 (dudect's "probably not constant time")
 *          no_evidence   enough measurements, |t| <= 10
 *          insufficient  budget ran out before dudect's 10,000-measurement floor
 *
 * "no_evidence" is not a proof of constant time: it means this test, on this
 * machine, with this budget, saw no timing difference between the classes.
 */
#ifndef PQ_DUDECT_RUN_H
#define PQ_DUDECT_RUN_H

#include <stdio.h>

extern double dudect_last_max_t, dudect_last_n;

/* dudect's measure() discards do_one_computation()'s result. Because the
 * dudect implementation is compiled into the same file, an optimising
 * compiler can prove a side-effect-free computation is dead and delete it,
 * so the test would time an empty loop. Every harness XORs its result in
 * here to keep the work observable. */
static volatile uint8_t dudect_sink;

static int dudect_run(const char *tier, const char *target, const char *op, size_t chunk,
                      double seconds, size_t per_batch) {
    dudect_config_t cfg = {.chunk_size = chunk, .number_measurements = per_batch};
    dudect_ctx_t ctx;
    dudect_init(&ctx, &cfg);
    uint64_t t0 = pq_now_ns();
    dudect_state_t st = DUDECT_NO_LEAKAGE_EVIDENCE_YET;
    double el = 0;
    while (el < seconds) {
        st = dudect_main(&ctx);
        el = (double)(pq_now_ns() - t0) / 1e9;
        if (st == DUDECT_LEAKAGE_FOUND) break;
    }
    const char *verdict = st == DUDECT_LEAKAGE_FOUND ? "leak"
                          : dudect_last_n < DUDECT_ENOUGH_MEASUREMENTS ? "insufficient"
                                                                       : "no_evidence";
    printf("RESULT,%s,%s,%s,%s,%.0f,%.2f,%s,%.1f\n", tier, target, op, cpucycles_unit(),
           dudect_last_n, dudect_last_max_t, verdict, el);
    fflush(stdout);
    dudect_free(&ctx);
    return 0;
}

#endif
