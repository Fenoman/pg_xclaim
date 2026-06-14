# pg_xclaim - PostgreSQL extension for high-cardinality xact-claims
#
# Build:
#   make PG_CONFIG=/opt/homebrew/Cellar/postgresql@17/17.9/bin/pg_config
#
# Default discovers `pg_config` from PATH. ABI-compatible PostgreSQL
# forks are built via local PG_CONFIG override.

MODULE_big = pg_xclaim
EXTENSION  = pg_xclaim

# Source objects compiled into pg_xclaim.so.
OBJS = \
	src/pg_xclaim.o \
	src/pg_xclaim_local.o \
	src/pg_xclaim_shared.o \
	src/pg_xclaim_acquire.o \
	src/pg_xclaim_callbacks.o \
	src/pg_xclaim_reaper.o \
	src/pg_xclaim_stats.o \
	src/pg_xclaim_session.o

# Versioned install SQL. Upgrade scripts (e.g. pg_xclaim--1.0.0-rc1--1.0.0.sql)
# will be added alongside on subsequent releases.
DATA = \
	sql/pg_xclaim--1.0.0-rc1.sql

# Regression test list. The main suite runs with
# shared_preload_libraries='pg_xclaim' (test/regress.conf).
# Cross-session tests live in the concurrency shell suite.
#
# NOTE: REGRESS is kept here for PGXS compatibility, but the main installcheck
# target is overridden below to use --temp-instance (required for preloading).
# All temp clusters live under /tmp.
REGRESS = \
	basic \
	conflict_local \
	rollback \
	subtxn \
	twophase_reject \
	advisory_zero \
	plpgsql_exception \
	keyspace \
	function_attributes \
	topmem_leak \
	database_isolation \
	session_reset_public_grant \
	bulk_array_shape \
	sql_surface \
	debug_inject_stale_hardening \
	enabled_off_contract

# Suppress default PGXS installcheck -- we define our own below that uses
# --temp-instance so shared_preload_libraries can be applied.
# PGXS installcheck would run against a running cluster without our preload.
NO_INSTALLCHECK = 1

# Strict compiler flags -- extension MUST build clean (-Wall -Wextra -Werror).
PG_CFLAGS = -Wall -Wextra -Werror -Wno-unused-parameter -Wno-declaration-after-statement

# Flat-file pg_regress artefacts removed by `make clean` via PGXS EXTRA_CLEAN
# (`rm -f`). The results/ and log/ output directories are removed recursively
# by the `clean-test-dirs` hook below, since EXTRA_CLEAN's `rm -f` skips dirs.
EXTRA_CLEAN = \
	test/regression.diffs test/regression.out \
	test/capacity/regression.diffs test/capacity/regression.out \
	test/nonpreload/regression.diffs test/nonpreload/regression.out \
	test/lwlocks/regression.diffs test/lwlocks/regression.out

# pg_config discovery: explicit override wins, otherwise look in PATH.
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# -------------------------------------------------------------------------
# pg_regress binary and bin directory (resolved after PGXS include)
# -------------------------------------------------------------------------
BINDIR    := $(shell $(PG_CONFIG) --bindir)
# pg_regress location: derived from the PGXS path.
# $(PGXS) = .../pgxs/src/makefiles/pgxs.mk
# pg_regress is at .../pgxs/src/test/regress/pg_regress
PGXS_SRCDIR    := $(shell dirname $(shell dirname $(PGXS)))
REGRESS_BINARY := $(PGXS_SRCDIR)/test/regress/pg_regress

# Temporary instance directories under /tmp.
REGRESS_TMPDIR     := /tmp/pg_xclaim_$(USER)_regress
REGRESS_CAP_TMPDIR := /tmp/pg_xclaim_$(USER)_capacity
REGRESS_NP_TMPDIR  := /tmp/pg_xclaim_$(USER)_nonpreload
REGRESS_LW_TMPDIR  := /tmp/pg_xclaim_$(USER)_lwlocks

# -------------------------------------------------------------------------
# Prerequisite for every installcheck* target below: the pg_xclaim.so and
# its SQL must already be present in pg_config --pkglibdir / --sharedir.
# Run `sudo make install` (or have write access to those dirs) beforehand.
# The targets deliberately do NOT depend on `install`: that PGXS phony
# target re-copies into root-owned dirs on packaged PGDG builds, which
# fails for an unprivileged `make installcheck`.
# -------------------------------------------------------------------------

# -------------------------------------------------------------------------
# installcheck: main regression suite with shared_preload_libraries='pg_xclaim'.
# Uses --temp-instance so the cluster is started fresh with test/regress.conf.
# Temp cluster lives under /tmp; pg_regress cleans it up automatically.
# -------------------------------------------------------------------------
.PHONY: installcheck
installcheck:
	mkdir -p test/results
	mkdir -p test/expected
	$(REGRESS_BINARY) \
		--inputdir=test \
		--outputdir=test \
		--expecteddir=test/expected \
		--temp-instance=$(REGRESS_TMPDIR) \
		--temp-config=$(CURDIR)/test/regress.conf \
		--load-extension=pg_xclaim \
		$(REGRESS)

# -------------------------------------------------------------------------
# installcheck-capacity: isolated temp cluster with max_claims=64
# (above the dynahash 32-freelist floor; never use a smaller value).
# SQL files live in test/capacity/sql/; expected in test/capacity/expected/.
# -------------------------------------------------------------------------
.PHONY: installcheck-capacity
installcheck-capacity:
	mkdir -p test/capacity/results
	mkdir -p test/capacity/expected
	$(REGRESS_BINARY) \
		--inputdir=test/capacity \
		--outputdir=test/capacity \
		--expecteddir=test/capacity/expected \
		--temp-instance=$(REGRESS_CAP_TMPDIR) \
		--temp-config=$(CURDIR)/test/capacity.conf \
		--load-extension=pg_xclaim \
		cap_error cap_warn cap_bulk_rollback cap_bulk_subtxn_rollback cap_warn_bulk_suppression

# -------------------------------------------------------------------------
# installcheck-nonpreload: temp cluster WITHOUT pg_xclaim preloaded.
# XCLAIM_REQUIRE_INIT() must raise ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE.
# SQL files live in test/nonpreload/sql/; expected in test/nonpreload/expected/.
# -------------------------------------------------------------------------
.PHONY: installcheck-nonpreload
installcheck-nonpreload:
	mkdir -p test/nonpreload/results
	mkdir -p test/nonpreload/expected
	$(REGRESS_BINARY) \
		--inputdir=test/nonpreload \
		--outputdir=test/nonpreload \
		--expecteddir=test/nonpreload/expected \
		--temp-instance=$(REGRESS_NP_TMPDIR) \
		--temp-config=$(CURDIR)/test/nonpreload.conf \
		nonpreload_smoke

# -------------------------------------------------------------------------
# installcheck-lwlocks: temp cluster with num_partitions=256, which
# exceeds the 192-LWLock budget that xclaim.debug() and
# xclaim.debug_snapshot() require for the all-partition scan. Both
# helpers must raise a clean ERRCODE_FEATURE_NOT_SUPPORTED with an
# actionable hint; the acquisition path must remain usable after the
# refusal (no partition LWLock leaked across the ereport unwind).
# SQL files live in test/lwlocks/sql/; expected in test/lwlocks/expected/.
# -------------------------------------------------------------------------
.PHONY: installcheck-lwlocks
installcheck-lwlocks:
	mkdir -p test/lwlocks/results
	mkdir -p test/lwlocks/expected
	$(REGRESS_BINARY) \
		--inputdir=test/lwlocks \
		--outputdir=test/lwlocks \
		--expecteddir=test/lwlocks/expected \
		--temp-instance=$(REGRESS_LW_TMPDIR) \
		--temp-config=$(CURDIR)/test/lwlocks.conf \
		--load-extension=pg_xclaim \
		lwlocks_guard

# -------------------------------------------------------------------------
# installcheck-smoke: pre-deploy smoke gate.
# Wraps scripts/smoke_gate.sh -- runs `postgres --single` against a temp
# datadir with shared_preload_libraries='pg_xclaim'; FAILs if FATAL/PANIC
# is emitted during _PG_init. The paired no-preload variant covers the
# LOAD-without-preload path.
# -------------------------------------------------------------------------
.PHONY: installcheck-smoke
installcheck-smoke: install
	bash $(CURDIR)/scripts/smoke_gate.sh $(PG_CONFIG)

.PHONY: installcheck-smoke-no-preload
installcheck-smoke-no-preload: install
	bash $(CURDIR)/scripts/smoke_gate_no_preload.sh $(PG_CONFIG)

# -------------------------------------------------------------------------
# clean-test-dirs: recursive removal of pg_regress output directories.
# Hooked onto PGXS `clean` because EXTRA_CLEAN uses `rm -f`, which leaves
# directories behind. Flat artefact files are handled by EXTRA_CLEAN above.
# -------------------------------------------------------------------------
.PHONY: clean-test-dirs
clean-test-dirs:
	rm -rf test/results test/log \
		test/capacity/results \
		test/nonpreload/results \
		test/lwlocks/results

clean: clean-test-dirs
