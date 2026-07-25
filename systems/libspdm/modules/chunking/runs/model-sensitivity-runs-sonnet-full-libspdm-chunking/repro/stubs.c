/* Stubs for functions used by libspdm_device_secret_lib_sample but not
 * needed in these chunking-only reproduction tests. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>

bool libspdm_read_input_file(const char *file_name, void **file_data, size_t *file_size)
{ (void)file_name; (void)file_data; (void)file_size; return false; }

bool libspdm_write_output_file(const char *file_name, const void *file_data, size_t file_size)
{ (void)file_name; (void)file_data; (void)file_size; return false; }

void libspdm_dump_hex_str(const uint8_t *buffer, size_t buffer_size)
{ (void)buffer; (void)buffer_size; }
