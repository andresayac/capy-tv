# Capy TV sync server: one static Go binary (SQLite included) on an empty base image.
FROM golang:1.26.11-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN apk add --no-cache ca-certificates
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/server . && mkdir /data

FROM scratch
COPY --from=build /out/server /server
# Root certificates, for the HTTPS of the language model's service (AI_MODEL)
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build --chown=65532:65532 /data /data
USER 65532:65532
ENV PORT=8080 DATA=/data/sync.db
EXPOSE 8080
VOLUME /data
HEALTHCHECK --interval=30s --timeout=5s CMD ["/server", "healthcheck"]
ENTRYPOINT ["/server"]
