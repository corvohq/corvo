package server

import (
	"testing"
	"time"
)

func BenchmarkAllowN_GlobalDefault(b *testing.B) {
	rl := newRateLimiter(RateLimitConfig{
		Enabled:    true,
		ReadRPS:    10000,
		ReadBurst:  20000,
		WriteRPS:   5000,
		WriteBurst: 10000,
	})
	defer rl.close()
	now := time.Now()

	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		key := "api:abcdef1234567890"
		for pb.Next() {
			rl.allowN(key, false, 1, now)
		}
	})
}

func BenchmarkAllowN_WithNamespaceOverride(b *testing.B) {
	rl := newRateLimiter(RateLimitConfig{
		Enabled:    true,
		ReadRPS:    10000,
		ReadBurst:  20000,
		WriteRPS:   5000,
		WriteBurst: 10000,
	})
	defer rl.close()

	// Simulate populated namespace config cache.
	nsMap := map[string]*RateLimitConfig{
		"tenant-a": {Enabled: true, ReadRPS: 50000, ReadBurst: 100000, WriteRPS: 25000, WriteBurst: 50000},
		"tenant-b": {Enabled: true, ReadRPS: 1000, ReadBurst: 2000, WriteRPS: 500, WriteBurst: 1000},
	}
	rl.nsConfigs.Store(&nsMap)

	keyMap := map[string]string{
		"api:abcdef1234567890": "tenant-a",
		"api:1234567890abcdef": "tenant-b",
	}
	rl.keyNS.Store(&keyMap)

	now := time.Now()

	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		key := "api:abcdef1234567890"
		for pb.Next() {
			rl.allowN(key, false, 1, now)
		}
	})
}

func BenchmarkAllowN_NoMatchFallsToGlobal(b *testing.B) {
	rl := newRateLimiter(RateLimitConfig{
		Enabled:    true,
		ReadRPS:    10000,
		ReadBurst:  20000,
		WriteRPS:   5000,
		WriteBurst: 10000,
	})
	defer rl.close()

	// Populated maps but this key won't match — exercises the miss path.
	nsMap := map[string]*RateLimitConfig{
		"tenant-a": {Enabled: true, ReadRPS: 50000, ReadBurst: 100000, WriteRPS: 25000, WriteBurst: 50000},
	}
	rl.nsConfigs.Store(&nsMap)
	keyMap := map[string]string{
		"api:otherkeyhere1234": "tenant-a",
	}
	rl.keyNS.Store(&keyMap)

	now := time.Now()

	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		key := "api:abcdef1234567890"
		for pb.Next() {
			rl.allowN(key, false, 1, now)
		}
	})
}

func BenchmarkConfigForKey_Hit(b *testing.B) {
	rl := newRateLimiter(RateLimitConfig{
		Enabled:  true,
		ReadRPS:  10000,
		ReadBurst: 20000,
	})
	defer rl.close()

	nsMap := map[string]*RateLimitConfig{
		"tenant-a": {Enabled: true, ReadRPS: 50000, ReadBurst: 100000, WriteRPS: 25000, WriteBurst: 50000},
	}
	rl.nsConfigs.Store(&nsMap)
	keyMap := map[string]string{
		"api:abcdef1234567890": "tenant-a",
	}
	rl.keyNS.Store(&keyMap)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		rl.configForKey("api:abcdef1234567890")
	}
}

func BenchmarkConfigForKey_Miss(b *testing.B) {
	rl := newRateLimiter(RateLimitConfig{
		Enabled:  true,
		ReadRPS:  10000,
		ReadBurst: 20000,
	})
	defer rl.close()

	nsMap := map[string]*RateLimitConfig{
		"tenant-a": {Enabled: true, ReadRPS: 50000, ReadBurst: 100000, WriteRPS: 25000, WriteBurst: 50000},
	}
	rl.nsConfigs.Store(&nsMap)
	keyMap := map[string]string{
		"api:otherkeyhere1234": "tenant-a",
	}
	rl.keyNS.Store(&keyMap)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		rl.configForKey("api:abcdef1234567890")
	}
}
