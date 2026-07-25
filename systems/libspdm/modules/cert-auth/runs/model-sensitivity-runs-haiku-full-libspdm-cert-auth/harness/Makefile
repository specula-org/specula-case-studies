# Makefile for libspdm trace harness
CC ?= gcc
CFLAGS ?= -Wall -Wextra -g -fPIC

SRC_DIR = src
SOURCES = $(SRC_DIR)/tla_trace.c $(SRC_DIR)/test_trace_scenario.c
HEADERS = $(SRC_DIR)/tla_trace.h
OBJECTS = $(SOURCES:.c=.o)
TARGET = bin/trace_test

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(OBJECTS)
	@mkdir -p bin
	$(CC) $(CFLAGS) -pthread -o $@ $^

$(SRC_DIR)/%.o: $(SRC_DIR)/%.c $(HEADERS)
	$(CC) $(CFLAGS) -pthread -c -o $@ $<

clean:
	rm -f $(OBJECTS) $(TARGET)
	rm -rf bin/
