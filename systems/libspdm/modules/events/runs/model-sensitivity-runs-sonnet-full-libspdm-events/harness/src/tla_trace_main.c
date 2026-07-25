/**
 * TLA+ Trace Runner — entry point for the tla_trace test executable.
 */

#include "spdm_unit_test.h"

int libspdm_tla_scenarios_test(void);

int main(void)
{
    int ret = 0;
    ret += libspdm_tla_scenarios_test();
    return ret;
}
