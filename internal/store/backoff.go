package store

import (
	"math"
	"time"
)

// CalculateBackoff returns the delay before the next retry attempt.
func CalculateBackoff(strategy string, attempt, baseDelayMs, maxDelayMs int) time.Duration {
	var delayMs int

	switch strategy {
	case BackoffNone:
		delayMs = 0
	case BackoffFixed:
		delayMs = baseDelayMs
	case BackoffLinear:
		delayMs = baseDelayMs * attempt
	case BackoffExponential:
		delayMs = baseDelayMs * int(math.Pow(2, float64(attempt-1)))
	default:
		delayMs = baseDelayMs * int(math.Pow(2, float64(attempt-1)))
	}

	if maxDelayMs > 0 && delayMs > maxDelayMs {
		delayMs = maxDelayMs
	}

	return time.Duration(delayMs) * time.Millisecond
}
