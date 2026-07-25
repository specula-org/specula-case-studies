package tla_trace

// State is a thin builder around the spec's per-server state map.
//
// Callers do not need to memorise the exact JSON keys (mode, waitSync,
// poolHeight, ...); they call Set("poolHeight", 3) and the resulting map
// is consumed by the *IfLogged wrappers in Trace.tla.
type State map[string]interface{}

// NewState returns an empty State map.
func NewState() State { return State{} }

// Set adds a key/value (chainable).
func (s State) Set(k string, v interface{}) State {
	s[k] = v
	return s
}

// SetIf adds k=v only when the boolean cond is true. Useful when a capture
// is conditional (e.g., mode field only known for nodes that have a reactor).
func (s State) SetIf(cond bool, k string, v interface{}) State {
	if cond {
		s[k] = v
	}
	return s
}

// Msg is the analogous builder for the event.msg field.
type Msg map[string]interface{}

// NewMsg returns an empty Msg map.
func NewMsg() Msg { return Msg{} }

// Set adds a key/value (chainable).
func (m Msg) Set(k string, v interface{}) Msg {
	m[k] = v
	return m
}

// Peer is the analogous builder for the event.peer field.
type Peer map[string]interface{}

// NewPeer returns an empty Peer map.
func NewPeer() Peer { return Peer{} }

// Set adds a key/value (chainable).
func (p Peer) Set(k string, v interface{}) Peer {
	p[k] = v
	return p
}
