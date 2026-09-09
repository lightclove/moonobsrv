# Tor-контейнер: только клиент, SOCKS для локальной сети compose.
# Здоровье = полностью бутстрапнулся (PROGRESS=100 на control-порту).
FROM alpine:3.22
RUN apk add --no-cache tor lyrebird \
    && mkdir -p /var/lib/tor \
    && chown -R tor:tor /var/lib/tor
COPY torrc /etc/tor/torrc
USER tor
EXPOSE 9050
HEALTHCHECK --interval=10s --timeout=5s --start-period=180s --retries=18 \
    CMD printf 'AUTHENTICATE\nGETINFO status/bootstrap-phase\nQUIT\n' | nc 127.0.0.1 9051 | grep -q 'PROGRESS=100' || exit 1
CMD ["tor", "-f", "/etc/tor/torrc"]
