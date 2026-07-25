.PHONY: all test clean

TRACES_DIR := /home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/libspdm-secured-message/traces

all: $(TRACES_DIR) test_trace_module

$(TRACES_DIR):
	mkdir -p $(TRACES_DIR)

test_trace_module: src/tla_trace.c src/tla_trace.h src/test_trace_module.c
	gcc -I./src -pthread -o test_trace_module src/tla_trace.c src/test_trace_module.c
	./test_trace_module

test: all

clean:
	rm -f test_trace_module

show-traces:
	@if [ -f "$(TRACES_DIR)/test_trace_module.ndjson" ]; then \
		echo "=== Trace Events ==="; \
		cat "$(TRACES_DIR)/test_trace_module.ndjson" | python3 -m json.tool; \
	else \
		echo "No trace file found yet. Run 'make test' first."; \
	fi

.PHONY: show-traces
