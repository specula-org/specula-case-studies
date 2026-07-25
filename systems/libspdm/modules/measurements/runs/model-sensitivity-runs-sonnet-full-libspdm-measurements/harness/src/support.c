/**
 * support.c — Platform I/O stubs required by spdm_device_secret_lib_sample.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

bool libspdm_read_input_file(const char *file_name, void **file_data,
                              size_t *file_size)
{
    FILE *fp = fopen(file_name, "rb");
    if (!fp) {
        fprintf(stderr, "Unable to open file %s\n", file_name);
        *file_data = NULL;
        return false;
    }
    fseek(fp, 0, SEEK_END);
    *file_size = (size_t)ftell(fp);
    *file_data = malloc(*file_size);
    if (!*file_data) {
        fclose(fp);
        return false;
    }
    fseek(fp, 0, SEEK_SET);
    if (fread(*file_data, 1, *file_size, fp) != *file_size) {
        free(*file_data);
        *file_data = NULL;
        fclose(fp);
        return false;
    }
    fclose(fp);
    return true;
}

bool libspdm_write_output_file(const char *file_name, const void *file_data,
                                size_t file_size)
{
    FILE *fp = fopen(file_name, "w+b");
    if (!fp) return false;
    fwrite(file_data, 1, file_size, fp);
    fclose(fp);
    return true;
}

void libspdm_dump_hex_str(const uint8_t *buffer, size_t buffer_size)
{
    (void)buffer;
    (void)buffer_size;
}
