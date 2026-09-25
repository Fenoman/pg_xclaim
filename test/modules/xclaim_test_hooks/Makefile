# Test-only module for test/concurrency (see xclaim_test_hooks.c).
# test/concurrency/_lib.sh builds it in a temporary directory:
#   make PG_CONFIG=<pg_config> XCLAIM_SRC=<repository>/src
MODULES = xclaim_test_hooks

XCLAIM_SRC ?= ../../../src
PG_CPPFLAGS = -I$(XCLAIM_SRC)
PG_CFLAGS = -Wall -Wextra -Werror -Wno-unused-parameter -Wno-declaration-after-statement

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
