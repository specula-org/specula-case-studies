CC = gcc
CFLAGS = -Wall -Wextra -fPIC -pthread
LDFLAGS = -pthread

SRC_DIR = src
BUILD_DIR = build
OUTPUT_DIR = ../traces

# Create output directory
$(shell mkdir -p $(BUILD_DIR) $(OUTPUT_DIR))

# Source files
SOURCES = $(SRC_DIR)/tla_trace.c $(SRC_DIR)/test_measurements.c
OBJECTS = $(patsubst $(SRC_DIR)/%.c,$(BUILD_DIR)/%.o,$(SOURCES))
TARGET = $(BUILD_DIR)/test_measurements

all: $(TARGET)

$(TARGET): $(OBJECTS)
	@echo "Linking $@..."
	$(CC) $(LDFLAGS) -o $@ $^

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.c
	@echo "Compiling $<..."
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -rf $(BUILD_DIR)

run: $(TARGET)
	@echo "Running test harness..."
	$(TARGET) $(OUTPUT_DIR)/trace.ndjson
	@echo "Traces saved to $(OUTPUT_DIR)"

.PHONY: all clean run
