FROM alpine:3.20

RUN apk add --no-cache dnsmasq tcpdump

COPY dnsmasq.conf /etc/dnsmasq.conf

# --keep-in-foreground, --no-daemon: keep dnsmasq attached to the container's
# PID 1 so Docker can supervise/restart it and logs go to stdout/stderr.
ENTRYPOINT ["dnsmasq", "-k", "--log-facility=-"]
