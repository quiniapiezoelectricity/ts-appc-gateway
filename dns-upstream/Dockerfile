FROM alpine:3.19@sha256:6baf43584bcb78f2e5847d1de515f23499913ac9f12bdf834811a3145eb11ca1
RUN apk add --no-cache unbound ca-certificates
# Default config path — overridden by command: in docker-compose.yml.
CMD ["unbound", "-d", "-c", "/config/unbound.conf"]
