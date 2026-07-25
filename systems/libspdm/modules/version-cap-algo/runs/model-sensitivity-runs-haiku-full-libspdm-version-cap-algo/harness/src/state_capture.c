#include "state_capture.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

char *capture_requester_state = NULL;
char *capture_responder_state = NULL;
bool capture_version_negotiated = false;
bool capture_capabilities_negotiated = false;
bool capture_algorithms_negotiated = false;
int capture_negotiated_version = 0;
const char *capture_local_algos_req = "[]";
const char *capture_local_algos_resp = "[]";

void state_capture_requester_state(const char *state) {
    if (capture_requester_state != NULL) free(capture_requester_state);
    capture_requester_state = state ? strdup(state) : NULL;
}

void state_capture_responder_state(const char *state) {
    if (capture_responder_state != NULL) free(capture_responder_state);
    capture_responder_state = state ? strdup(state) : NULL;
}

void state_capture_version_negotiated(bool value) {
    capture_version_negotiated = value;
}

void state_capture_capabilities_negotiated(bool value) {
    capture_capabilities_negotiated = value;
}

void state_capture_algorithms_negotiated(bool value) {
    capture_algorithms_negotiated = value;
}

void state_capture_negotiated_version(int version) {
    capture_negotiated_version = version;
}

void state_capture_local_algos_req(const char *algos) {
    capture_local_algos_req = algos ? algos : "[]";
}

void state_capture_local_algos_resp(const char *algos) {
    capture_local_algos_resp = algos ? algos : "[]";
}

char *build_state_json(void) {
    char *buf = malloc(1024);
    if (buf == NULL) return NULL;

    snprintf(buf, 1024,
             "{\"requester_state\":\"%s\",\"responder_state\":\"%s\","
             "\"version_negotiated\":%s,\"capabilities_negotiated\":%s,"
             "\"algorithms_negotiated\":%s,\"negotiated_version\":%d,"
             "\"local_algos_req\":%s,\"local_algos_resp\":%s}",
             capture_requester_state ? capture_requester_state : "unknown",
             capture_responder_state ? capture_responder_state : "unknown",
             capture_version_negotiated ? "true" : "false",
             capture_capabilities_negotiated ? "true" : "false",
             capture_algorithms_negotiated ? "true" : "false",
             capture_negotiated_version,
             capture_local_algos_req ? capture_local_algos_req : "[]",
             capture_local_algos_resp ? capture_local_algos_resp : "[]");

    return buf;
}

char *build_event_json_version(int version) {
    char *buf = malloc(256);
    if (buf == NULL) return NULL;
    snprintf(buf, 256, "{\"version\":%d}", version);
    return buf;
}

char *build_event_json_algos(const char *algos, bool validation_passed) {
    char *buf = malloc(512);
    if (buf == NULL) return NULL;
    snprintf(buf, 512, "{\"agreed_algos\":%s,\"algorithms_negotiated\":%s}",
             algos ? algos : "0", validation_passed ? "true" : "false");
    return buf;
}

char *build_event_json_proposed_algos(const char *algos, bool prioritization_failed) {
    char *buf = malloc(512);
    if (buf == NULL) return NULL;
    snprintf(buf, 512, "{\"proposed_algos\":%s,\"prioritization_failed\":%s}",
             algos ? algos : "[]", prioritization_failed ? "true" : "false");
    return buf;
}

void cleanup_json_strings(void) {
    if (capture_requester_state != NULL) {
        free(capture_requester_state);
        capture_requester_state = NULL;
    }
    if (capture_responder_state != NULL) {
        free(capture_responder_state);
        capture_responder_state = NULL;
    }
}
