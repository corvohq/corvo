.PHONY: build run test perf lint clean ui ui-dev

BINARY := jobbie
BUILD_DIR := bin

ui:
	cd ui && npm install && npm run build

build: ui
	CGO_ENABLED=1 go build -o $(BUILD_DIR)/$(BINARY) ./cmd/jobbie

bench:
	CGO_ENABLED=1 go build -o $(BUILD_DIR)/bench ./cmd/bench

run: build
	./$(BUILD_DIR)/$(BINARY) server

test:
	CGO_ENABLED=1 go test ./... -v -count=1

perf:
	CGO_ENABLED=1 go test -tags perf ./tests/perf -v -count=1

lint:
	golangci-lint run ./...

clean:
	rm -rf $(BUILD_DIR) ui/dist ui/node_modules

ui-dev:
	cd ui && npm run dev
