package enterprise

import (
	"crypto/ed25519"
	"encoding/base64"
	"fmt"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// License represents validated enterprise entitlements.
type License struct {
	Customer string
	Tier     string
	Features map[string]struct{}
	Expires  time.Time
}

// HasFeature reports whether a validated license enables the named feature.
func (l *License) HasFeature(name string) bool {
	if l == nil {
		return false
	}
	_, ok := l.Features[strings.ToLower(strings.TrimSpace(name))]
	return ok
}

// FeatureList returns enabled feature names.
func (l *License) FeatureList() []string {
	if l == nil {
		return nil
	}
	out := make([]string, 0, len(l.Features))
	for k := range l.Features {
		out = append(out, k)
	}
	return out
}

type claims struct {
	Customer string   `json:"customer"`
	Tier     string   `json:"tier"`
	Features []string `json:"features"`
	jwt.RegisteredClaims
}

// ParsePublicKey decodes a base64-encoded Ed25519 public key.
func ParsePublicKey(v string) (ed25519.PublicKey, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(v))
	if err != nil {
		return nil, fmt.Errorf("decode public key: %w", err)
	}
	if len(raw) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("invalid public key size %d", len(raw))
	}
	return ed25519.PublicKey(raw), nil
}

// Validate verifies and parses an enterprise license JWT signed with Ed25519.
func Validate(token string, pub ed25519.PublicKey, now time.Time) (*License, error) {
	if strings.TrimSpace(token) == "" {
		return nil, fmt.Errorf("missing license token")
	}
	if len(pub) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("invalid license public key")
	}
	c := claims{}
	parsed, err := jwt.ParseWithClaims(strings.TrimSpace(token), &c, func(t *jwt.Token) (any, error) {
		if t.Method == nil || t.Method.Alg() != jwt.SigningMethodEdDSA.Alg() {
			return nil, fmt.Errorf("unexpected signing algorithm")
		}
		return pub, nil
	}, jwt.WithLeeway(2*time.Minute), jwt.WithTimeFunc(func() time.Time { return now.UTC() }))
	if err != nil {
		return nil, fmt.Errorf("validate license: %w", err)
	}
	if !parsed.Valid {
		return nil, fmt.Errorf("invalid license")
	}
	features := map[string]struct{}{}
	for _, f := range c.Features {
		f = strings.ToLower(strings.TrimSpace(f))
		if f == "" {
			continue
		}
		features[f] = struct{}{}
	}
	expires := time.Time{}
	if c.ExpiresAt != nil {
		expires = c.ExpiresAt.Time.UTC()
	}
	return &License{
		Customer: strings.TrimSpace(c.Customer),
		Tier:     strings.ToLower(strings.TrimSpace(c.Tier)),
		Features: features,
		Expires:  expires,
	}, nil
}
