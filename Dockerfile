# Runtime-образ: статический musl-бинарь кросс-компилируется на dev-машине
# (deploy.ps1: zig build -Dtarget=x86_64-linux-musl) и кладётся в dist/.
# На проде ничего не собирается и не скачивается — только alpine + сертификаты.

FROM alpine:3.21
# ca-certificates — TLS к api.telegram.org; tzdata не нужна (пояс = фикс. смещение).
RUN apk add --no-cache ca-certificates
COPY dist/moonobsrv /moonobsrv
# tar из Windows не сохраняет exec-бит
RUN chmod 0755 /moonobsrv
ENTRYPOINT ["/moonobsrv"]
