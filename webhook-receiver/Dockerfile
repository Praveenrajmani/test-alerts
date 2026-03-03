FROM golang:1.22-bookworm AS builder
WORKDIR /app
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -o /webhook-receiver .

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /webhook-receiver /usr/local/bin/webhook-receiver
EXPOSE 9090
ENTRYPOINT ["webhook-receiver"]
