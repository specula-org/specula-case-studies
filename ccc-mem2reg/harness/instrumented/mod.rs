pub(crate) mod promote;
pub(crate) mod phi_eliminate;
pub(crate) mod tla_trace;
pub(crate) mod trace_helpers;
#[cfg(test)]
mod trace_scenarios;

pub(crate) use promote::promote_allocas;
pub(crate) use promote::promote_allocas_with_params;
pub(crate) use phi_eliminate::eliminate_phis;
