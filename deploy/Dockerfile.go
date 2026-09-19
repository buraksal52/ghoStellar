# One Dockerfile for every Go service — ARG SERVICE picks the binary
# (docs/reference/platform/architecture.md's boot patterns; the plan's
# "Docker / Compose" section). Build context is repo root so the module's
# single go.mod is reachable.
#
#   docker build -f deploy/Dockerfile.go --build-arg SERVICE=authsvc -t ghostellar/authsvc .

FROM golang:1.26-alpine AS builder
ARG SERVICE
WORKDIR /src

COPY backend/go.mod backend/go.sum ./backend/
RUN cd backend && go mod download

COPY backend ./backend
RUN cd backend \
    && CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/service ./cmd/${SERVICE}

FROM alpine:3.19
# wget (healthcheck) + ca-certificates (Horizon/Soroban/anchor TLS) + a
# shell for debugging — deliberately not distroless yet (plan's "Docker /
# Compose": go-builder/distroless optimizations wait until builds hurt).
RUN apk --no-cache add ca-certificates tzdata wget \
    && addgroup -S app && adduser -S app -G app
COPY --from=builder /out/service /app/service
USER app
ENV GOMEMLIMIT=200MiB GOGC=100
ENTRYPOINT ["/app/service"]
