FROM alpine:3.19
RUN apk add --no-cache dnsmasq
# Default config path — overridden by command: in docker-compose.yml.
CMD ["dnsmasq", "--conf-file=/config/dnsmasq-steer.conf", "--no-daemon"]
