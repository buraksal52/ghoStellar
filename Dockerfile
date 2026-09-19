# Railway builds from the repository root, so copy the Go module from
# backend/ and build the monolith entrypoint.
FROM golang:1.26-alpine AS builder
WORKDIR /src

COPY backend/go.mod backend/go.sum ./backend/
RUN cd backend && go mod download

COPY backend ./backend
RUN cd backend \
    && mkdir -p /out \
    && CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/ghoStellar ./cmd/monolith

FROM golang:1.26-alpine AS migrator
RUN CGO_ENABLED=0 go install -tags 'postgres' github.com/golang-migrate/migrate/v4/cmd/migrate@v4.17.1

FROM alpine:3.19
RUN apk --no-cache add ca-certificates tzdata \
    && addgroup -S app && adduser -S app -G app
COPY --from=builder /out/ghoStellar /app/ghoStellar
COPY --from=migrator /go/bin/migrate /app/migrate
COPY deploy/migrations /app/migrations
COPY scripts/railway-predeploy.sh /app/railway-predeploy.sh
RUN chmod 0555 /app/railway-predeploy.sh
USER app
ENV GOMEMLIMIT=200MiB GOGC=100
EXPOSE 8080
CMD ["/app/ghoStellar"]
