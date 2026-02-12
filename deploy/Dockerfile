# Build stage
FROM golang:1.23-bookworm AS builder

RUN apt-get update && apt-get install -y gcc libc6-dev && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=1 GOOS=linux go build -o /jobbie ./cmd/jobbie

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=builder /jobbie /usr/local/bin/jobbie

RUN mkdir -p /data
VOLUME /data

EXPOSE 8080

ENTRYPOINT ["jobbie"]
CMD ["server", "--data-dir", "/data", "--addr", ":8080"]
