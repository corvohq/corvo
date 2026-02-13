package store

import "errors"

type ErrorCode string

const (
	ErrorCodeOverloaded ErrorCode = "OVERLOADED"
)

type StoreError struct {
	Code         ErrorCode
	Msg          string
	RetryAfterMs int
}

func (e *StoreError) Error() string {
	return e.Msg
}

func NewOverloadedError(msg string) error {
	return &StoreError{Code: ErrorCodeOverloaded, Msg: msg}
}

func NewOverloadedErrorRetry(msg string, retryAfterMs int) error {
	if retryAfterMs < 0 {
		retryAfterMs = 0
	}
	return &StoreError{Code: ErrorCodeOverloaded, Msg: msg, RetryAfterMs: retryAfterMs}
}

func IsOverloadedError(err error) bool {
	if err == nil {
		return false
	}
	var se *StoreError
	if !errors.As(err, &se) {
		return false
	}
	return se.Code == ErrorCodeOverloaded
}

func OverloadRetryAfterMs(err error) (int, bool) {
	if err == nil {
		return 0, false
	}
	var se *StoreError
	if !errors.As(err, &se) {
		return 0, false
	}
	if se.Code != ErrorCodeOverloaded {
		return 0, false
	}
	return se.RetryAfterMs, se.RetryAfterMs > 0
}
