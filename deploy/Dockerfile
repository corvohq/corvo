# Build stage
FROM golang:1.24-bookworm AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /corvo ./cmd/corvo

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=builder /corvo /usr/local/bin/corvo

RUN mkdir -p /data
VOLUME /data

EXPOSE 8080

ENTRYPOINT ["corvo"]
CMD ["server", "--data-dir", "/data", "--bind", ":8080"]
