package anchor

const (
	ErrNotAllowed       = "anchor.not_allowed"
	ErrTomlUnavailable  = "anchor.toml_unavailable"
	ErrAuthRequired     = "anchor.auth_required"
	ErrTokenRejected    = "anchor.token_rejected"
	ErrUpstreamFailed   = "anchor.upstream_failed"
	ErrBadRequest       = "anchor.bad_request"
	ErrDBNotReady       = "anchor.db_not_ready"
	ErrTrustlineMissing = "anchor.trustline_missing"
	ErrChainUnavailable = "chain.rpc_unavailable"
	// ErrAccountNotFunded: the caller's Stellar account doesn't exist
	// on-chain yet (0 XLM, never funded). Building a tx against it would
	// use a bogus sequence number (0) and Horizon would reject it with a
	// result code the client doesn't recognize — this fails fast instead.
	ErrAccountNotFunded = "anchor.account_not_funded"
)
