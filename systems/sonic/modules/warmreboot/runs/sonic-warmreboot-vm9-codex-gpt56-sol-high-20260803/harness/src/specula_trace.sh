#!/bin/bash

specula_trace_event()
{
    local event_name="$1"
    local event_source="$2"
    local event_asic="$3"
    local event_component="$4"
    shift 4

    [[ -n "${SPECULA_TRACE_SOCKET:-}" ]] || return 0
    local args=("$event_name" "$event_source")
    [[ -n "$event_asic" ]] && args+=(--asic "$event_asic")
    [[ -n "$event_component" ]] && args+=(--component "$event_component")
    "${SPECULA_TRACE_EMITTER:?SPECULA_TRACE_EMITTER is required}" "${args[@]}" "$@"
}

specula_trace_component_selected()
{
    local wanted=",${SPECULA_TRACE_COMPONENTS:-orchagent,xcvrd},"
    [[ "$wanted" == *",$1,"* ]]
}
