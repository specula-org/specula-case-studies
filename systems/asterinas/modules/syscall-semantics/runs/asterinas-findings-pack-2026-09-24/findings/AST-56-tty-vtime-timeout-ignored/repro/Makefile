CC ?= cc
CFLAGS ?= -std=c11 -O2 -Wall -Wextra -Werror
LDLIBS ?= -lrt
.PHONY: all static clean
all: bin/abi_probe
bin/abi_probe: src/abi_probe.c src/legacy_cases.inc
	mkdir -p bin
	$(CC) $(CFLAGS) $(LDFLAGS) src/abi_probe.c $(LDLIBS) -o $@
static:
	$(MAKE) clean
	$(MAKE) LDFLAGS="$(LDFLAGS) -static"
clean:
	rm -f bin/abi_probe
