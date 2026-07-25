#ifndef STATE_CAPTURE_H
#define STATE_CAPTURE_H

#include "tla_trace.h"

extern char *capture_requester_state;
extern char *capture_responder_state;
extern bool capture_version_negotiated;
extern bool capture_capabilities_negotiated;
extern bool capture_algorithms_negotiated;
extern int capture_negotiated_version;
extern const char *capture_local_algos_req;
extern const char *capture_local_algos_resp;

void state_capture_requester_state(const char *state);
void state_capture_responder_state(const char *state);
void state_capture_version_negotiated(bool value);
void state_capture_capabilities_negotiated(bool value);
void state_capture_algorithms_negotiated(bool value);
void state_capture_negotiated_version(int version);
void state_capture_local_algos_req(const char *algos);
void state_capture_local_algos_resp(const char *algos);

char *build_state_json(void);
char *build_event_json_version(int version);
char *build_event_json_algos(const char *algos, bool validation_passed);
char *build_event_json_proposed_algos(const char *algos, bool prioritization_failed);

void cleanup_json_strings(void);

#endif
