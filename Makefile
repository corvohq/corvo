.PHONY: build run test lint clean

BINARY := jobbie
BUILD_DIR := bin

build:
	CGO_ENABLED=1 go build -o $(BUILD_DIR)/$(BINARY) ./cmd/jobbie

run: build
	./$(BUILD_DIR)/$(BINARY) server

test:
	CGO_ENABLED=1 go test ./... -v -count=1

lint:
	golangci-lint run ./...

clean:
	rm -rf $(BUILD_DIR)
