.PHONY: build run test perf lint clean ui ui-dev bench bench-modes bench-baseline bench-profile

BINARY := corvo
BUILD_DIR := bin

ui:
	cd ui && npm install && npm run build

build: ui
	go build -o $(BUILD_DIR)/$(BINARY) ./cmd/corvo

bench: build
	./$(BUILD_DIR)/$(BINARY) bench

bench-modes:
	./scripts/bench-modes.sh

bench-baseline:
	./scripts/bench-baseline.sh

bench-profile:
	./scripts/bench-profile.sh

run: build
	./$(BUILD_DIR)/$(BINARY) server

test:
	go test ./... -v -count=1

perf:
	go test -tags perf ./tests/perf -v -count=1

lint:
	golangci-lint run ./...

clean:
	rm -rf $(BUILD_DIR) ui/dist ui/node_modules

ui-dev:
	cd ui && npm run dev
