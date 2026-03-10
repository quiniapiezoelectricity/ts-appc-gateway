FROM alpine:3.19
RUN apk add --no-cache unbound ca-certificates
# Default config path — overridden by command: in docker-compose.yml.
CMD ["unbound", "-d", "-c", "/config/unbound.conf"]
