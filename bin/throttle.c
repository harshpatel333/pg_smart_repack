/*
 * throttle.c: paced copy, automatic back-off, progress reporting and the
 * maximum-runtime guard for pg_repack (struct-throttle build).
 *
 * See throttle.h. All database access for monitoring goes through a
 * separate autocommit connection ("monconn"): pg_stat_activity and
 * pg_stat_replication are cached for the duration of a transaction, so they
 * cannot be sampled from inside pg_repack's long copy transaction.
 */
#include "pgut/pgut-fe.h"
#include "throttle.h"

#include <errno.h>
#include <math.h>
#include <signal.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/time.h>

#define GB	(1024.0 * 1024.0 * 1024.0)
#define MB	(1024.0 * 1024.0)

/* Minimum seconds between two samples of the monitoring metrics. */
#define METRICS_MIN_AGE		1.0
/* Granularity of interruptible sleeps. */
#define SLEEP_CHUNK			0.2
/* Heap pages sampled for the informational live-size estimate. */
#define SIZE_SAMPLE_PAGES	2000.0

int		thr_copy_slice_pages = THR_DEFAULT_COPY_SLICE_PAGES;
double	thr_duty_cycle = THR_DEFAULT_DUTY_CYCLE;
double	thr_max_slice_sleep = THR_DEFAULT_MAX_SLICE_SLEEP;
int		thr_backoff_io_waiters = THR_DEFAULT_BACKOFF_IO_WAITERS;
double	thr_backoff_wal_gb = THR_DEFAULT_BACKOFF_WAL_GB;
double	thr_backoff_replica_lag = THR_DEFAULT_BACKOFF_REPLICA_LAG;
double	thr_backoff_step = THR_DEFAULT_BACKOFF_STEP;
double	thr_backoff_max = THR_DEFAULT_BACKOFF_MAX;
double	thr_max_runtime = THR_DEFAULT_MAX_RUNTIME;
double	thr_progress_interval = THR_DEFAULT_PROGRESS_INTERVAL;
bool	thr_enabled = false;

/*
 * Informational lines (settings, size, progress) are printed only in
 * throttled mode, and never under pg_regress, so stock output is unchanged.
 */
static bool
thr_chatty(void)
{
	static int	under_regress = -1;

	if (under_regress < 0)
	{
		const char *app = getenv("PGAPPNAME");

		under_regress = (app && strncmp(app, "pg_regress", 10) == 0);
	}
	return thr_enabled && !under_regress;
}

/* runtime guard */
static double	run_deadline = 0;		/* 0 = no deadline */

/* per-table state */
static PGconn  *monconn = NULL;
static bool		mon_active = false;	/* monitoring wanted for this table */
static bool		mon_down = false;	/* warned that monitoring is unavailable */
static double	mon_retry_at = 0;
static int		mon_pid = 0;
#define MON_RETRY_SECS	10.0
static Oid		cur_oid = InvalidOid;
static char	   *cur_name = NULL;
static int		own_pids[8];
static int		n_own_pids = 0;
static bool		wal_ok = false;

static const char *phase = "setup";
static double	phase_start = 0;
static uint64	copy_total = 0;
static uint64	copy_done = 0;
static double	copy_start = 0;
static long		apply_rows = 0;

/* apply pacing (thr_pace_apply) */
static double	prev_backlog = -1;
static bool		full_speed = false;
static double	checked_at = 0;

/* reporting */
static double	last_report = 0;
static double	last_bytes = -1;
static double	last_bytes_at = 0;

/* current back-off episode */
static const char *backoff_reason = NULL;
static double	backoff_value = 0;

/* last metrics sample */
static double	metrics_at = 0;
static double	m_wal_bytes = -1;
static int		m_io_waiters = -1;
static double	m_replica_lag = -1;
static double	m_snap_secs = -1;
static double	m_snap_xids = -1;

double
thr_now(void)
{
	struct timeval tv;

	gettimeofday(&tv, NULL);
	return tv.tv_sec + tv.tv_usec / 1e6;
}

/* ------------------------------------------------------------------------
 * option parsing
 * ------------------------------------------------------------------------ */

/* Parse "500ms", "30", "30s", "10m", "10min", "4h", "1.5h", "1d". */
static bool
parse_duration(const char *arg, double *out)
{
	char	   *end;
	double		v;

	errno = 0;
	v = strtod(arg, &end);
	if (end == arg || errno != 0 || v < 0 || !isfinite(v))
		return false;
	while (*end == ' ')
		end++;
	if (*end == '\0' || strcmp(end, "s") == 0 || strcmp(end, "sec") == 0)
		;
	else if (strcmp(end, "ms") == 0)
		v /= 1000.0;
	else if (strcmp(end, "m") == 0 || strcmp(end, "min") == 0)
		v *= 60.0;
	else if (strcmp(end, "h") == 0)
		v *= 3600.0;
	else if (strcmp(end, "d") == 0)
		v *= 86400.0;
	else
		return false;
	*out = v;
	return true;
}

static bool
parse_number(const char *arg, double *out)
{
	char	   *end;
	double		v;

	errno = 0;
	v = strtod(arg, &end);
	if (end == arg || *end != '\0' || errno != 0 || !isfinite(v))
		return false;
	*out = v;
	return true;
}

typedef struct
{
	const char *lname;
	double	   *var;
	bool		duration;	/* accepts unit suffixes */
} thr_dbl_opt;

static thr_dbl_opt dbl_opts[] =
{
	{"duty-cycle", &thr_duty_cycle, false},
	{"max-slice-sleep", &thr_max_slice_sleep, true},
	{"backoff-wal-gb", &thr_backoff_wal_gb, false},
	{"backoff-replica-lag", &thr_backoff_replica_lag, true},
	{"backoff-step", &thr_backoff_step, true},
	{"backoff-max", &thr_backoff_max, true},
	{"max-runtime", &thr_max_runtime, true},
	{"progress-interval", &thr_progress_interval, true},
	{NULL, NULL, false}
};

void
thr_setopt(pgut_option *opt, const char *arg)
{
	thr_dbl_opt *o;

	for (o = dbl_opts; o->lname; o++)
	{
		if (strcmp(o->lname, opt->lname) != 0)
			continue;
		if (arg == NULL ||
			!(o->duration ? parse_duration(arg, o->var) : parse_number(arg, o->var)))
			ereport(ERROR,
				(errcode(EINVAL),
				 errmsg("option --%s should be %s: '%s'", opt->lname,
						o->duration ? "a duration such as 30s, 10m or 4h" : "a number",
						arg ? arg : "")));
		return;
	}
	ereport(ERROR, (errcode(EINVAL), errmsg("unknown option --%s", opt->lname)));
}

const char *
thr_validate(void)
{
	if (thr_copy_slice_pages < 0)
		return "--copy-slice-pages must be >= 0 (0 copies in one statement)";
	if (!(thr_duty_cycle > 0 && thr_duty_cycle <= 1))
		return "--duty-cycle must be > 0 and <= 1 (1 disables pacing)";
	if (thr_max_slice_sleep < 0)
		return "--max-slice-sleep must be >= 0";
	if (thr_backoff_io_waiters < 0)
		return "--backoff-io-waiters must be >= 0 (0 disables it)";
	if (thr_backoff_wal_gb < 0)
		return "--backoff-wal-gb must be >= 0 (0 disables it)";
	if (thr_backoff_replica_lag < 0)
		return "--backoff-replica-lag must be >= 0 (0 disables it)";
	if (thr_backoff_step <= 0)
		return "--backoff-step must be > 0";
	if (thr_backoff_max < 0)
		return "--backoff-max must be >= 0";
	if (thr_max_runtime < 0 || thr_max_runtime > 365 * 86400.0)
		return "--max-runtime must be between 0 (disabled) and 365d";
	if (thr_progress_interval < 0)
		return "--progress-interval must be >= 0 (0 disables progress lines)";
	return NULL;
}

/* ------------------------------------------------------------------------
 * formatting helpers
 * ------------------------------------------------------------------------ */

static const char *
fmt_dur(double secs, char *buf, size_t len)
{
	long	s;

	if (secs < 0 || !isfinite(secs))
	{
		snprintf(buf, len, "?");
		return buf;
	}
	s = (long) (secs + 0.5);
	if (s >= 3600)
		snprintf(buf, len, "%ldh%02ldm", s / 3600, (s % 3600) / 60);
	else if (s >= 60)
		snprintf(buf, len, "%ldm%02lds", s / 60, s % 60);
	else
		snprintf(buf, len, "%lds", s);
	return buf;
}

static const char *
fmt_gb(double bytes, char *buf, size_t len)
{
	if (bytes < 0)
		snprintf(buf, len, "n/a");
	else
		snprintf(buf, len, "%.2fGB", bytes / GB);
	return buf;
}

/* ------------------------------------------------------------------------
 * max-runtime guard
 *
 * SIGALRM is handled by pgut like SIGINT/SIGTERM: running statements are
 * cancelled and the next CHECK_FOR_INTERRUPTS() raises an error, which runs
 * the cleanup callback. pgut_interrupt_signo == SIGALRM marks the reason.
 * ------------------------------------------------------------------------ */

static void
set_alarm(double secs)
{
	struct itimerval it;

	memset(&it, 0, sizeof(it));
	if (secs > 0)
	{
		it.it_value.tv_sec = (time_t) secs;
		it.it_value.tv_usec = (suseconds_t) ((secs - floor(secs)) * 1e6);
		if (it.it_value.tv_sec == 0 && it.it_value.tv_usec == 0)
			it.it_value.tv_usec = 1;
	}
	setitimer(ITIMER_REAL, &it, NULL);
}

void
thr_arm_runtime(void)
{
	char	buf[32];

	if (thr_max_runtime <= 0)
		return;
	run_deadline = thr_now() + thr_max_runtime;
	set_alarm(thr_max_runtime);
	if (thr_chatty())
		elog(INFO, "max-runtime guard armed: %s", fmt_dur(thr_max_runtime, buf, sizeof(buf)));
}

/* Called right before the swap: the swap must not be interrupted by the
 * runtime guard (signals are still honoured). */
void
thr_disarm_runtime(void)
{
	if (run_deadline > 0)
		set_alarm(0);
}

void
thr_rearm_runtime(void)
{
	double	left;

	if (run_deadline <= 0)
		return;
	left = run_deadline - thr_now();
	set_alarm(left > 0.001 ? left : 0.001);
}

/* ------------------------------------------------------------------------
 * monitoring connection and metrics
 * ------------------------------------------------------------------------ */

void
thr_add_own_pid(PGconn *conn)
{
	if (conn && n_own_pids < (int) lengthof(own_pids))
	{
		int		pid = PQbackendPID(conn);
		int		i;

		for (i = 0; i < n_own_pids; i++)
			if (own_pids[i] == pid)
				return;
		own_pids[n_own_pids++] = pid;
	}
}

static const char *
own_pids_array(char *buf, size_t len)
{
	int		i;
	size_t	off = 0;

	off += snprintf(buf + off, len - off, "{%d", mon_pid);
	for (i = 0; i < n_own_pids && off < len; i++)
		off += snprintf(buf + off, len - off, ",%d", own_pids[i]);
	if (off < len)
		snprintf(buf + off, len - off, "}");
	return buf;
}

/* Open the monitoring connection; NULL (with a message at elevel) on failure. */
static PGconn *
mon_connect(int elevel)
{
	PGconn	   *c = pgut_connect(dbname, host, port, username, password,
								 prompt_password, elevel);

	if (c)
	{
		pgut_command(c, "SET statement_timeout = '30s'", 0, NULL);
		pgut_command(c, "SET lock_timeout = '5s'", 0, NULL);
		mon_pid = PQbackendPID(c);
	}
	return c;
}

/* Say loudly (once per outage) that back-off is blind, then retry. */
static void
mon_unavailable(const char *why)
{
	if (!mon_down)
		elog(WARNING, "monitoring unavailable (%s): back-off signals cannot fire"
			 " until it recovers; retrying every %.0fs", why, MON_RETRY_SECS);
	mon_down = true;
}

static PGresult *
mon_query(const char *sql, int nparams, const char **params)
{
	PGresult   *res;

	if (!mon_active)
		return NULL;
	if (monconn && PQstatus(monconn) != CONNECTION_OK)
	{
		pgut_disconnect(monconn);
		monconn = NULL;
	}
	if (!monconn)
	{
		if (thr_now() < mon_retry_at)
			return NULL;
		mon_retry_at = thr_now() + MON_RETRY_SECS;
		monconn = mon_connect(DEBUG2);
		if (!monconn)
		{
			mon_unavailable("cannot reconnect");
			return NULL;
		}
		if (mon_down)
			elog(INFO, "monitoring connection re-established; back-off signals active again");
		mon_down = false;
	}
	res = pgut_execute_elevel(monconn, sql, nparams, params, DEBUG2);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		char		why[160];

		snprintf(why, sizeof(why), "%s", PQerrorMessage(monconn));
		why[strcspn(why, "\n")] = '\0';
		CLEARPGRES(res);
		if (PQstatus(monconn) != CONNECTION_OK)
		{
			pgut_disconnect(monconn);
			monconn = NULL;
			mon_retry_at = 0;	/* reconnect on the next call */
		}
		mon_unavailable(why);
		return NULL;
	}
	return res;
}

static double
getdbl(PGresult *res, int row, int col, double dflt)
{
	if (PQgetisnull(res, row, col))
		return dflt;
	return atof(PQgetvalue(res, row, col));
}

static void
refresh_metrics(bool force)
{
	PGresult   *res;
	char		pids[128];
	const char *params[1];
	double		now = thr_now();

	if (!mon_active || (!force && now - metrics_at < METRICS_MIN_AGE))
		return;
	metrics_at = now;

	params[0] = own_pids_array(pids, sizeof(pids));
	res = mon_query(
		"SELECT"
		" (SELECT count(*) FROM pg_stat_activity"
		"   WHERE state = 'active' AND wait_event_type = 'IO'"
		"     AND backend_type IN ('client backend', 'parallel worker')"
		"     AND pid <> ALL ($1::int[])"
		"     AND coalesce(leader_pid, 0) <> ALL ($1::int[])),"
		" (SELECT coalesce(extract(epoch FROM max(replay_lag)), 0)"
		"    FROM pg_stat_replication),"
		" (SELECT extract(epoch FROM max(now() - xact_start))"
		"    FROM pg_stat_activity"
		"   WHERE pid = ANY ($1::int[]) AND backend_xmin IS NOT NULL),"
		" (SELECT max(age(backend_xmin))"
		"    FROM pg_stat_activity WHERE pid = ANY ($1::int[]))",
		1, params);
	if (res)
	{
		m_io_waiters = (int) getdbl(res, 0, 0, -1);
		m_replica_lag = getdbl(res, 0, 1, -1);
		m_snap_secs = getdbl(res, 0, 2, 0);
		m_snap_xids = getdbl(res, 0, 3, 0);
		CLEARPGRES(res);
	}
	else
	{
		/* Unknown, not "last seen": a stale value could pin a back-off. */
		m_io_waiters = -1;
		m_replica_lag = -1;
		m_snap_secs = m_snap_xids = -1;
	}

	if (wal_ok)
	{
		res = mon_query("SELECT coalesce(sum(size), 0) FROM pg_ls_waldir()", 0, NULL);
		if (res)
		{
			m_wal_bytes = getdbl(res, 0, 0, -1);
			CLEARPGRES(res);
		}
		else
			m_wal_bytes = -1;
	}
}

/* Informational size line, for planning only (not a gate). */
static void
log_size_estimate(Oid oid, const char *name)
{
	PGresult   *res;
	char		oidbuf[16];
	const char *params[1];
	double		total, heap, toast, idx, nblocks, pct, live = -1;
	char		b1[32], b2[32], b3[32], b4[32], b5[32], b6[32];
	StringInfoData sql;

	snprintf(oidbuf, sizeof(oidbuf), "%u", oid);
	params[0] = oidbuf;
	res = mon_query(
		"SELECT pg_total_relation_size(c.oid), pg_relation_size(c.oid),"
		"       coalesce(pg_total_relation_size(nullif(c.reltoastrelid, 0)), 0),"
		"       pg_indexes_size(c.oid),"
		"       pg_relation_size(c.oid) / current_setting('block_size')::bigint,"
		"       (SELECT string_agg(format('coalesce(pg_column_size(%I), 0)', attname),"
		"                          ' + ' ORDER BY attnum)"
		"          FROM pg_attribute"
		"         WHERE attrelid = c.oid AND attnum > 0 AND NOT attisdropped)"
		"  FROM pg_class c WHERE c.oid = $1::oid",
		1, params);
	if (!res || PQntuples(res) != 1)
	{
		CLEARPGRES(res);
		return;
	}
	total = getdbl(res, 0, 0, 0);
	heap = getdbl(res, 0, 1, 0);
	toast = getdbl(res, 0, 2, 0);
	idx = getdbl(res, 0, 3, 0);
	nblocks = getdbl(res, 0, 4, 0);

	if (!PQgetisnull(res, 0, 5) && nblocks > 0)
	{
		/*
		 * pg_column_size() of a TOASTed value is its stored size, read from
		 * the TOAST pointer without fetching the value, so this samples
		 * heap pages only. 24 bytes approximates the tuple header.
		 */
		PGresult *r2;

		pct = Min(100.0, 100.0 * SIZE_SAMPLE_PAGES / nblocks);
		initStringInfo(&sql);
		appendStringInfo(&sql,
			"SELECT coalesce(sum(24 + %s), 0)::float8 FROM ONLY %s"
			" TABLESAMPLE SYSTEM (%.6f) REPEATABLE (7151)",
			PQgetvalue(res, 0, 5), name, pct);
		r2 = mon_query(sql.data, 0, NULL);
		if (r2)
		{
			live = getdbl(r2, 0, 0, 0) * 100.0 / pct;
			CLEARPGRES(r2);
		}
		termStringInfo(&sql);
	}
	CLEARPGRES(res);

	elog(INFO, "size (informational, not a gate): table=%s on_disk=%s"
		 " (heap %s, toast %s, indexes %s)",
		 name, fmt_gb(total, b1, 32), fmt_gb(heap, b2, 32),
		 fmt_gb(toast, b3, 32), fmt_gb(idx, b4, 32));
	if (live >= 0)
		elog(INFO, "size: live_estimate=%s (sampled ~%.0f of %.0f heap pages);"
			 " projected_peak_extra=%s (live + indexes %s + ~%.0fGB WAL)",
			 fmt_gb(live, b5, 32), Min(SIZE_SAMPLE_PAGES, nblocks), nblocks,
			 fmt_gb(live + idx + THR_WAL_ALLOWANCE_GB * GB, b6, 32),
			 fmt_gb(idx, b4, 32), THR_WAL_ALLOWANCE_GB);
}

void
thr_begin_table(Oid target_oid, const char *target_name, bool dryrun)
{
	PGresult   *res;

	cur_oid = target_oid;
	if (cur_name)
		free(cur_name);
	cur_name = pgut_strdup(target_name);
	n_own_pids = 0;
	copy_total = copy_done = 0;
	apply_rows = 0;
	prev_backlog = -1;
	full_speed = false;
	checked_at = 0;
	last_bytes = -1;
	backoff_reason = NULL;
	metrics_at = 0;
	m_wal_bytes = -1;
	m_io_waiters = -1;
	m_replica_lag = -1;
	m_snap_secs = m_snap_xids = -1;
	wal_ok = false;
	thr_set_phase("setup");

	/* Stock (ordered) mode: no monitoring connection, no extra output. */
	if (!thr_enabled)
		return;

	if (!monconn)
		monconn = mon_connect(ERROR);
	mon_active = true;
	mon_down = false;
	thr_add_own_pid(connection);
	thr_add_own_pid(conn2);

	if (thr_chatty())
	{
		elog(INFO, "throttle: copy_slice_pages=%d duty_cycle=%.2f max_slice_sleep=%.0fs"
			 " backoff_io_waiters=%d backoff_wal_gb=%.1f backoff_replica_lag=%.0fs"
			 " backoff_step=%.0fs backoff_max=%.0fs progress_interval=%.0fs",
			 thr_copy_slice_pages, thr_duty_cycle, thr_max_slice_sleep,
			 thr_backoff_io_waiters, thr_backoff_wal_gb, thr_backoff_replica_lag,
			 thr_backoff_step, thr_backoff_max, thr_progress_interval);
		log_size_estimate(target_oid, target_name);
	}

	/* Can we read the WAL directory size? (pg_monitor or superuser) */
	res = pgut_execute_elevel(monconn,
		"SELECT coalesce(sum(size), 0) FROM pg_ls_waldir()", 0, NULL, DEBUG2);
	wal_ok = (PQresultStatus(res) == PGRES_TUPLES_OK);
	if (!wal_ok && thr_chatty() && thr_backoff_wal_gb > 0)
		elog(WARNING, "cannot read the WAL directory size (%s); the --backoff-wal-gb"
			 " signal is disabled for this run",
			 PQresultErrorMessage(res));
	CLEARPGRES(res);

	/*
	 * Checkpoints keep pg_wal at up to max_wal_size (plus wal_keep_size and
	 * slot retention) even when idle, so a threshold at or below that can
	 * hold a back-off - and the copy snapshot - until --max-runtime.
	 */
	if (wal_ok && thr_chatty() && thr_backoff_wal_gb > 0)
	{
		res = pgut_execute_elevel(monconn,
			"SELECT (pg_size_bytes(current_setting('max_wal_size'))"
			"      + pg_size_bytes(current_setting('wal_keep_size'))) / 1024.0^3,"
			"       (SELECT sum(size) FROM pg_ls_waldir()) / 1024.0^3",
			0, NULL, DEBUG2);
		if (PQresultStatus(res) == PGRES_TUPLES_OK)
		{
			double	steady = getdbl(res, 0, 0, 0);
			double	now_gb = getdbl(res, 0, 1, 0);

			if (thr_backoff_wal_gb <= steady)
				elog(WARNING, "--backoff-wal-gb=%.1f is at or below max_wal_size +"
					 " wal_keep_size (%.1fGB): pg_wal can stay that large at steady"
					 " state and hold the back-off until --max-runtime",
					 thr_backoff_wal_gb, steady);
			elog(INFO, "wal: pg_wal=%.1fGB now, max_wal_size+wal_keep_size=%.1fGB,"
				 " back-off threshold=%.1fGB", now_gb, steady, thr_backoff_wal_gb);
		}
		CLEARPGRES(res);
	}

	/* Without pg_read_all_stats, other roles' wait events and replay_lag are hidden. */
	res = pgut_execute_elevel(monconn,
		"SELECT pg_has_role('pg_read_all_stats', 'member')"
		"    OR (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)",
		0, NULL, DEBUG2);
	if (PQresultStatus(res) == PGRES_TUPLES_OK && strcmp(PQgetvalue(res, 0, 0), "t") != 0 &&
		thr_chatty() && (thr_backoff_io_waiters > 0 || thr_backoff_replica_lag > 0))
		elog(WARNING, "role is not a member of pg_read_all_stats: the io-waiters and"
			 " replica-lag signals only see this role's own sessions");
	CLEARPGRES(res);

	if (dryrun)
	{
		thr_end_table();
		return;
	}
}

void
thr_end_table(void)
{
	mon_active = false;
	if (monconn)
	{
		pgut_disconnect(monconn);
		monconn = NULL;
	}
}

/* ------------------------------------------------------------------------
 * progress
 * ------------------------------------------------------------------------ */

void
thr_set_phase(const char *p)
{
	phase = p;
	phase_start = thr_now();
	last_report = 0;	/* report early in each new phase */
	last_bytes = -1;
}

const char *
thr_get_phase(void)
{
	return phase;
}

void
thr_copy_start(uint64 total_pages)
{
	copy_total = total_pages;
	copy_done = 0;
	copy_start = thr_now();
	if (thr_chatty())
		elog(INFO, "copying %llu heap pages in slices of %d pages",
			 (unsigned long long) total_pages, thr_copy_slice_pages);
}

void
thr_copy_done_pages(uint64 pages_done)
{
	copy_done = pages_done;
}

void
thr_apply_done_rows(int rows)
{
	apply_rows += rows;
}

/* Size of repack.table_<oid> plus TOAST and indexes. Must be safe to run
 * inside the copy transaction: to_regclass() never errors. */
static double
temp_table_bytes(void)
{
	PGresult   *res;
	char		sql[160];
	double		v = -1;

	if (!connection || PQtransactionStatus(connection) == PQTRANS_INERROR ||
		PQtransactionStatus(connection) == PQTRANS_ACTIVE)
		return -1;
	snprintf(sql, sizeof(sql),
			 "SELECT pg_total_relation_size(to_regclass('repack.table_%u'))", cur_oid);
	if (PQtransactionStatus(connection) == PQTRANS_INTRANS)
	{
		/* Inside the copy transaction: a savepoint keeps any failure here
		 * from aborting the copy. */
		bool	ok;

		if (pgut_command(connection, "SAVEPOINT repack_progress", 0, NULL) != PGRES_COMMAND_OK)
			return -1;
		res = pgut_execute_elevel(connection, sql, 0, NULL, DEBUG2);
		ok = (PQresultStatus(res) == PGRES_TUPLES_OK);
		if (ok)
			v = getdbl(res, 0, 0, -1);
		CLEARPGRES(res);
		pgut_command(connection, ok ? "RELEASE SAVEPOINT repack_progress"
					 : "ROLLBACK TO SAVEPOINT repack_progress", 0, NULL);
		return v;
	}
	res = pgut_execute_elevel(connection, sql, 0, NULL, DEBUG2);
	if (PQresultStatus(res) == PGRES_TUPLES_OK)
		v = getdbl(res, 0, 0, -1);
	CLEARPGRES(res);
	return v;
}

/* Approximate number of rows waiting in repack.log_<oid>. */
static double
log_backlog(void)
{
	PGresult   *res;
	char		sql[200];
	double		v = -1;

	snprintf(sql, sizeof(sql),
			 "SELECT coalesce(max(id) - min(id) + 1, 0) FROM repack.log_%u", cur_oid);
	res = mon_query(sql, 0, NULL);
	if (res)
	{
		v = getdbl(res, 0, 0, -1);
		CLEARPGRES(res);
	}
	return v;
}

void
thr_maybe_report(bool force)
{
	double		now = thr_now();
	double		bytes, rate = -1;
	char		b1[32], b2[32], b3[32], b4[32], b5[32];
	StringInfoData line;

	if (thr_progress_interval <= 0 || !mon_active || !thr_chatty())
		return;
	if (!force && last_report > 0 && now - last_report < thr_progress_interval)
		return;
	last_report = now;

	refresh_metrics(true);
	bytes = temp_table_bytes();
	if (bytes >= 0 && last_bytes >= 0 && now > last_bytes_at)
		rate = (bytes - last_bytes) / (now - last_bytes_at);
	if (bytes >= 0)
	{
		last_bytes = bytes;
		last_bytes_at = now;
	}

	initStringInfo(&line);
	appendStringInfo(&line, "progress: table=%s phase=%s", cur_name ? cur_name : "?", phase);
	if (strcmp(phase, "copy") == 0 && copy_total > 0)
	{
		double	elapsed = now - copy_start;
		double	eta = -1;

		if (copy_done > 0 && elapsed > 0)
			eta = (copy_total - copy_done) / (copy_done / elapsed);
		appendStringInfo(&line, " pages=%llu/%llu (%.1f%%) eta=%s",
						 (unsigned long long) copy_done,
						 (unsigned long long) copy_total,
						 100.0 * copy_done / copy_total,
						 fmt_dur(eta, b1, sizeof(b1)));
	}
	else if (strcmp(phase, "apply") == 0)
		appendStringInfo(&line, " applied_rows=%ld log_backlog=%.0f",
						 apply_rows, log_backlog());
	appendStringInfo(&line, " written=%s", fmt_gb(bytes, b2, sizeof(b2)));
	if (rate >= 0)
		appendStringInfo(&line, " rate=%.1fMB/s", rate / MB);
	else
		appendStringInfoString(&line, " rate=n/a");
	appendStringInfo(&line, " phase_elapsed=%s", fmt_dur(now - phase_start, b3, sizeof(b3)));
	if (backoff_reason)
		appendStringInfo(&line, " backoff=%s(%.1f)", backoff_reason, backoff_value);
	else
		appendStringInfoString(&line, " backoff=none");
	appendStringInfo(&line, " wal=%s io_waiters=%d replica_lag=%.1fs snapshot_age=%s xmin_age=%.0f",
					 fmt_gb(m_wal_bytes, b4, sizeof(b4)), m_io_waiters,
					 m_replica_lag, fmt_dur(m_snap_secs, b5, sizeof(b5)), m_snap_xids);
	elog(INFO, "%s", line.data);
	termStringInfo(&line);
}

/* ------------------------------------------------------------------------
 * pacing and back-off
 * ------------------------------------------------------------------------ */

/* Sleep without blocking signals: wakes up every SLEEP_CHUNK to check for
 * an interrupt and to emit progress lines. */
void
thr_sleep(double seconds)
{
	double		end = thr_now() + seconds;

	for (;;)
	{
		double			left;
		struct timespec	ts;

		CHECK_FOR_INTERRUPTS();
		left = end - thr_now();
		if (left <= 0)
			break;
		if (left > SLEEP_CHUNK)
			left = SLEEP_CHUNK;
		ts.tv_sec = (time_t) left;
		ts.tv_nsec = (long) ((left - ts.tv_sec) * 1e9);
		nanosleep(&ts, NULL);	/* EINTR is fine: we re-check above */
		thr_maybe_report(false);
	}
	CHECK_FOR_INTERRUPTS();
}

void
thr_pace(double busy_seconds)
{
	double		s;

	if (!thr_enabled || thr_duty_cycle >= 1.0 || busy_seconds <= 0)
	{
		thr_maybe_report(false);
		return;
	}
	s = busy_seconds * (1.0 / thr_duty_cycle - 1.0);
	if (thr_max_slice_sleep > 0 && s > thr_max_slice_sleep)
		s = thr_max_slice_sleep;
	thr_sleep(s);
}

/*
 * Pacing for replay batches. Pacing helps only with the backlog that piled up
 * during the copy; in steady state replay writes no more than the app does.
 * So the first time the backlog grows between samples (the app is writing
 * faster than paced replay drains it), pacing is switched off for the rest of
 * the apply phase. Flipping back and forth would let the backlog hover and
 * never converge before --max-runtime.
 */
void
thr_pace_apply(double busy_seconds)
{
	double			now = thr_now();

	if (!thr_enabled || thr_duty_cycle >= 1.0)
	{
		thr_maybe_report(false);
		return;
	}
	if (now - checked_at >= METRICS_MIN_AGE)
	{
		double	backlog = log_backlog();

		checked_at = now;
		if (!full_speed && backlog >= 0 && prev_backlog >= 0 && backlog > prev_backlog)
		{
			elog(INFO, "apply: log backlog is growing (%.0f -> %.0f rows); replaying"
				 " at full speed for the rest of this phase", prev_backlog, backlog);
			full_speed = true;
		}
		prev_backlog = backlog;
	}
	if (full_speed)
		thr_maybe_report(false);
	else
		thr_pace(busy_seconds);
}

static const char *
check_backoff(double *value)
{
	refresh_metrics(false);
	if (thr_backoff_io_waiters > 0 && m_io_waiters >= thr_backoff_io_waiters)
	{
		*value = m_io_waiters;
		return "io-waiters";
	}
	if (wal_ok && thr_backoff_wal_gb > 0 && m_wal_bytes >= thr_backoff_wal_gb * GB)
	{
		*value = m_wal_bytes / GB;
		return "wal-gb";
	}
	if (thr_backoff_replica_lag > 0 && m_replica_lag >= thr_backoff_replica_lag)
	{
		*value = m_replica_lag;
		return "replica-lag";
	}
	return NULL;
}

void
thr_wait_backoff(void)
{
	double		episode_start = 0;
	const char *reason;
	double		value = 0;
	char		b1[32];

	CHECK_FOR_INTERRUPTS();
	if (!thr_enabled || !mon_active ||
		(thr_backoff_io_waiters <= 0 && thr_backoff_wal_gb <= 0 &&
		 thr_backoff_replica_lag <= 0))
	{
		thr_maybe_report(false);
		return;
	}

	for (;;)
	{
		reason = check_backoff(&value);
		if (!reason)
			break;

		if (episode_start == 0)
		{
			episode_start = thr_now();
			elog(INFO, "back-off: phase=%s signal=%s value=%.1f; pausing",
				 phase, reason, value);
		}
		else if (reason != backoff_reason)
			elog(INFO, "back-off: phase=%s signal=%s value=%.1f; still pausing",
				 phase, reason, value);
		else if (thr_backoff_max > 0 && thr_now() - episode_start > thr_backoff_max)
			elog(WARNING, "back-off has lasted %s (> --backoff-max): signal=%s value=%.1f;"
				 " still waiting",
				 fmt_dur(thr_now() - episode_start, b1, sizeof(b1)), reason, value);
		backoff_reason = reason;
		backoff_value = value;

		thr_sleep(thr_backoff_step);
		metrics_at = 0;		/* force a fresh sample */
	}

	if (episode_start > 0)
		elog(INFO, "back-off cleared after %s; resuming %s",
			 fmt_dur(thr_now() - episode_start, b1, sizeof(b1)), phase);
	backoff_reason = NULL;
	thr_maybe_report(false);
}

/* ------------------------------------------------------------------------
 * abort reporting
 * ------------------------------------------------------------------------ */

const char *
thr_abort_reason(void)
{
	switch (pgut_interrupt_signo)
	{
		case 0:
			return "error";
		case SIGALRM:
			return "max-runtime";
		case SIGTERM:
			return "SIGTERM";
		case SIGINT:
			return "SIGINT";
		default:
			return "signal";
	}
}

void
thr_report_abort(const char *table_name, bool cleaned)
{
	bool	swapped = (strcmp(phase, "drop") == 0 || strcmp(phase, "done") == 0);

	if (cleaned && swapped)
		fprintf(stderr, "pg_repack interrupted after swap: reason=%s table=%s"
				" (the table was repacked; temporary objects dropped)\n",
				thr_abort_reason(), table_name);
	else if (cleaned)
		fprintf(stderr, "pg_repack aborted cleanly: reason=%s table=%s phase=%s"
				" copied_pages=%llu/%llu\n",
				thr_abort_reason(), table_name, phase,
				(unsigned long long) copy_done, (unsigned long long) copy_total);
	else
		fprintf(stderr, "pg_repack abort cleanup FAILED: reason=%s table=%s phase=%s;"
				" temporary objects may be left behind, run abort-repack.sql\n",
				thr_abort_reason(), table_name, phase);
	fflush(stderr);
}
