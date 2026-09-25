#ifndef TERMO_CONNECTION_OPTIONS_H
#define TERMO_CONNECTION_OPTIONS_H
// Borrowed strings; valid for the duration of the blocking call. NULL options use defaults.
typedef struct {
    int timeout_ms;
    int heartbeat_ms;
    int proxy_kind; // 0=direct, 1=SOCKS5 (remote DNS), 2=HTTP CONNECT
    int proxy_port;
    const char *proxy_host;
    const char *host_key_algos;
    const char *ciphers;
    const char *kex_algos;
} TermoConnectionOptions;
#endif
