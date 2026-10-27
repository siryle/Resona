FROM --platform=$BUILDPLATFORM golang:1.27.3-alpine AS build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY go.mod go.sum VERSION.json version.go ./
COPY vendor ./vendor
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH GOPROXY=off GOSUMDB=off go build -mod=vendor -trimpath -buildvcs=false -ldflags="-s -w" -o /out/resona ./cmd/resona

FROM alpine:3.23
RUN apk add --no-cache ca-certificates ffmpeg tzdata && \
    addgroup -g 10001 resona && adduser -D -u 10001 -G resona resona && \
    mkdir -p /data /music/inbox /music/library && chown -R resona:resona /data /music && chmod -R 777 /music
COPY --from=build /out/resona /usr/local/bin/resona
COPY LICENSE THIRD_PARTY.md /usr/share/licenses/resona/
COPY vendor/github.com/amarnathcjd/gogram/LICENSE /usr/share/licenses/gogram/LICENSE
COPY vendor/github.com/skip2/go-qrcode/LICENSE /usr/share/licenses/go-qrcode/LICENSE
ENV LISTEN_ADDR=:8080 DATA_PATH=/data INBOX_PATH=/music/inbox LIBRARY_PATH=/music/library
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["/usr/local/bin/resona"]
