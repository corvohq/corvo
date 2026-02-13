.PHONY: build run test perf lint clean

BINARY := jobbie
BUILD_DIR := bin

bench:
	CGO_ENABLED=1 go build -o $(BUILD_DIR)/bench ./cmd/bench

build:
	CGO_ENABLED=1 go build -o $(BUILD_DIR)/$(BINARY) ./cmd/jobbie

run: build
	./$(BUILD_DIR)/$(BINARY) server

test:
	CGO_ENABLED=1 go test ./... -v -count=1

perf:
	CGO_ENABLED=1 go test -tags perf ./tests/perf -v -count=1

lint:
	golangci-lint run ./...

clean:
	rm -rf $(BUILD_DIR)
