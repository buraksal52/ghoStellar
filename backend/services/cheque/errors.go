package cheque

// Error codes match the plan's "Hata kodları" list and the p2p doc's case
// catalog (A1-A6, F3, H2, D5) one-to-one.
const (
	ErrInsufficientBalance   = "cheque.insufficient_balance"  // A1
	ErrAlreadyActive         = "cheque.already_active"        // A3
	ErrInvalidReceiver       = "cheque.invalid_receiver"      // A4
	ErrReceiverNoTrustline   = "cheque.receiver_no_trustline" // A4/F3
	ErrSelfTransfer          = "cheque.self_transfer"         // A5
	ErrInvalidAmount         = "cheque.invalid_amount"        // A6
	ErrExpired               = "cheque.expired"
	ErrTerminalState         = "cheque.terminal_state"
	ErrNotFound              = "cheque.not_found"
	ErrPoolWithdrawLocked    = "pool.withdraw_locked"     // H2
	ErrPoolOperationInFlight = "pool.operation_in_flight" // D5
	ErrBadRequest            = "cheque.bad_request"
	ErrDBNotReady            = "cheque.db_not_ready"
	ErrChainUnavailable      = "chain.rpc_unavailable"
)
