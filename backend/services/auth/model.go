package auth

import "time"

// User is a minimal profile row keyed by the Stellar address that proved
// ownership via SEP-10 — there is no password, no email; identity IS the
// chain keypair (docs/reference/platform/architecture.md §1 rule 3).
type User struct {
	ID             int64
	StellarAddress string
	DisplayName    string
	CreatedAt      time.Time
}

// TokenPair is what /auth/token and /auth/refresh return.
type TokenPair struct {
	AccessToken  string `json:"accessToken"`
	RefreshToken string `json:"refreshToken"`
	ExpiresIn    int64  `json:"expiresIn"` // seconds, access token lifetime
}
