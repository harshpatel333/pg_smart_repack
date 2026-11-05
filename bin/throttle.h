/*
 * throttle.h: paced copy, automatic back-off, progress reporting and the
 * maximum-runtime guard for pg_repack (struct-throttle build).
 *
 * Everything here is client-side only. It works against the stock
 * pg_repack server extension: the only server objects used are the ones
 * the stock client already uses, plus built-in functions and views.
 */
#ifndef REPACK_THROTTLE_H
#define REPACK_THROTTLE_H

#include "pgut/pgut-fe.h"

/* Printed by --version next to the (unchanged) REPACK_VERSION. */
#define THROTTLE_BUILD_TAG "struct-throttle 1"

/* Defaults. Every knob can be turned off with 0 (duty cycle: 1). */
#define THR_DEFAULT_COPY_SLICE_PAGES	1024
#define THR_DEFAULT_DUTY_CYCLE			0.33
#define THR_DEFAULT_MAX_SLICE_SLEEP		30.0		/* seconds */
#define THR_DEFAULT_BACKOFF_IO_WAITERS	16
#define THR_DEFAULT_BACKOFF_WAL_GB		35.0
#define THR_DEFAULT_BACKOFF_REPLICA_LAG	60.0		/* seconds */
#define THR_DEFAULT_BACKOFF_STEP		10.0		/* seconds */
#define THR_DEFAULT_BACKOFF_MAX			600.0		/* seconds */
#define THR_DEFAULT_MAX_RUNTIME			(4 * 3600.0)	/* seconds */
#define THR_DEFAULT_PROGRESS_INTERVAL	60.0		/* seconds */

/* Rule-of-thumb WAL allowance used only in the informational size line. */
#define THR_WAL_ALLOWANCE_GB			20.0

/* Settings (set from the command line by pg_repack.c). */
extern int		thr_copy_slice_pages;
extern double	thr_duty_cycle;
extern double	thr_max_slice_sleep;
extern int		thr_backoff_io_waiters;
extern double	thr_backoff_wal_gb;
extern double	thr_backoff_replica_lag;
extern double	thr_backoff_step;
extern double	thr_backoff_max;
extern double	thr_max_runtime;
extern double	thr_progress_interval;

/*
 * True when pacing, slicing and back-off are active. Decided in main():
 * only in --no-order mode.
 */
extern bool		thr_enabled;

/* Option callback ('f' type) for every duration / fractional option. */
extern void thr_setopt(pgut_option *opt, const char *arg);

/* Validate settings; returns NULL if fine, else an error message. */
extern const char *thr_validate(void);

/* Max-runtime guard. */
extern void thr_arm_runtime(void);
extern void thr_disarm_runtime(void);
extern void thr_rearm_runtime(void);

/* Per-table lifecycle. */
extern void thr_begin_table(Oid target_oid, const char *target_name, bool dryrun);
extern void thr_end_table(void);
extern void thr_add_own_pid(PGconn *conn);

/* Progress. Phases: "setup", "copy", "index", "apply", "swap", "drop". */
extern void thr_set_phase(const char *phase);
extern const char *thr_get_phase(void);
extern void thr_copy_start(uint64 total_pages);
extern void thr_copy_done_pages(uint64 pages_done);
extern void thr_apply_done_rows(int rows);
extern void thr_maybe_report(bool force);

/* Pacing and back-off. */
extern void thr_wait_backoff(void);
extern void thr_pace(double busy_seconds);
extern void thr_sleep(double seconds);
extern double thr_now(void);

/* Abort reporting. */
extern const char *thr_abort_reason(void);
extern void thr_report_abort(const char *table_name, bool cleaned);

#endif   /* REPACK_THROTTLE_H */
