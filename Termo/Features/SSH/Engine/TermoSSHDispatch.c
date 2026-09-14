//  SSH 引擎（russh）适配层：Swift 侧调用符号保持 termo_ssh_* / termo_sftp_* / termo_key_*，
//  本文件把旧引擎 ABI 1:1 前转 russh（termo_russh_*）；libssh2 实现已移除。
//
//  语义对齐承诺见 TermoRusshCore.h 头注；差异点：
//  · termo_ssh_exec 的输出缓冲由适配层补 NUL（russh 侧为二进制安全）
//  · termo_ssh_test 的 stage1/2 由适配层自测（DNS/TCP），russh 一次完成握手+认证
#include "TermoSSHCore.h"
#include "TermoRusshCore.h"

#include <stdio.h>
#include <netdb.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

// ── 会话 ────────────────────────────────────────────────────────────────────

TermoSSHSession *termo_ssh_open(const char *host, int port,
                                const char *user, const char *password,
                                const char *key_path, const char *key_passphrase,
                                const char *real_known_hosts, const char *session_known_hosts,
                                char *err, int errlen) {
    return (TermoSSHSession *)termo_russh_session_open(
        host, port, user, password, key_path, key_passphrase,
        real_known_hosts, session_known_hosts,
        NULL, 0, 20000, err, errlen);
}

const char *termo_ssh_session_sha256(TermoSSHSession *s) {
    return termo_russh_session_sha256((TermoRusshSession *)s);
}

const char *termo_ssh_session_md5(TermoSSHSession *s) {
    return termo_russh_session_md5((TermoRusshSession *)s);
}

void termo_ssh_cancel(TermoSSHSession *s) {
    termo_russh_session_cancel((TermoRusshSession *)s);
}

void termo_ssh_close(TermoSSHSession *s) {
    termo_russh_session_close((TermoRusshSession *)s);
}

// ── 主机密钥扫描 ────────────────────────────────────────────────────────────

void termo_ssh_scan_hostkey(const char *host, int port,
                            const char *real_known_hosts, const char *session_known_hosts,
                            TermoHostKeyScan *out) {
    if (!out) return;
    TermoRusshHostKeyScan scan;
    memset(&scan, 0, sizeof(scan));
    if (termo_russh_scan_hostkey(host, port, real_known_hosts, session_known_hosts, &scan) == 0) {
        memcpy(out, &scan, sizeof(scan));   // 字段布局一致
    } else {
        out->status = -1;
    }
}

// ── 分阶段测试连接（DNS/TCP 自测 + 一次会话建立）────────────────────────────

static int test_tcp_probe(const char *host, int port) {
    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%d", port);
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port_str, &hints, &res) != 0 || !res) return 1;   // DNS 失败
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) { freeaddrinfo(res); return 1; }
    int rc = connect(fd, res->ai_addr, res->ai_addrlen);
    freeaddrinfo(res);
    close(fd);
    return rc == 0 ? 0 : 2;   // 0=TCP OK；2=TCP 失败
}

void termo_ssh_test(const char *host, int port, const char *user,
                    const char *password, const char *key_path, const char *key_passphrase,
                    TermoSSHStageCallback on_stage, void *userdata) {
    char msg[512];
    // stage 1/2：DNS + TCP（适配层自测，失败即止）
    int tcp = test_tcp_probe(host, port);
    if (tcp == 1) {
        snprintf(msg, sizeof(msg), "无法解析主机 %s", host);
        on_stage(userdata, 1, 0, msg);
        return;
    }
    on_stage(userdata, 1, 1, "主机解析成功");
    if (tcp == 2) {
        snprintf(msg, sizeof(msg), "无法建立 TCP 连接 %s:%d", host, port);
        on_stage(userdata, 2, 0, msg);
        return;
    }
    on_stage(userdata, 2, 1, "TCP 连接成功");

    // stage 3/4/5：握手 + 认证（一次会话建立；按错误文案归位失败阶段）
    char err[512];
    TermoRusshSession *s = termo_russh_session_open(
        host, port, user, password, key_path, key_passphrase,
        NULL, NULL, NULL, 0, 20000, err, (int)sizeof(err));
    if (!s) {
        int stage = 3;   // 默认归为握手阶段失败
        if (strncmp(err, "HOSTKEY_MISMATCH", 16) == 0) stage = 3;
        else if (strstr(err, "认证") || strstr(err, "私钥") || strstr(err, "密码")) stage = 4;
        on_stage(userdata, stage, 0, err);
        return;
    }
    on_stage(userdata, 3, 1, "SSH 握手成功");
    on_stage(userdata, 4, 1, "身份验证成功");
    on_stage(userdata, 5, 1, "连接完成");
    termo_russh_session_close(s);
}

// ── exec ────────────────────────────────────────────────────────────────────

int termo_ssh_exec(TermoSSHSession *s, const char *command,
                   char *out, int out_cap, char *errout, int errout_cap,
                   int *exit_code, char *err, int errlen) {
    int out_len = 0, err_len = 0;
    int rc = termo_russh_exec2((TermoRusshSession *)s, command,
                               NULL, 0,
                               out, out_cap > 0 ? out_cap - 1 : 0, &out_len,
                               errout, errout_cap > 0 ? errout_cap - 1 : 0, &err_len,
                               exit_code, 20000, err, errlen);
    if (rc != 0) return -1;   // 超时/取消按旧口径归为错误
    if (out && out_cap > 0) out[out_len] = '\0';
    if (errout && errout_cap > 0) errout[err_len < errout_cap ? err_len : errout_cap - 1] = '\0';
    return 0;
}

int termo_ssh_exec2(TermoSSHSession *s, const char *command,
                    const char *stdin_bytes, int stdin_len,
                    char *out, int out_cap, int *out_len,
                    char *errout, int errout_cap, int *err_len,
                    int *exit_code, int timeout_ms, char *err, int errlen) {
    return termo_russh_exec2((TermoRusshSession *)s, command, stdin_bytes, stdin_len,
                             out, out_cap, out_len, errout, errout_cap, err_len,
                             exit_code, timeout_ms, err, errlen);
}

int termo_ssh_exec_upload(TermoSSHSession *s, const char *command,
                          TermoSSHPullCallback pull, void *userdata,
                          int *exit_code, char *err, int errlen) {
    return termo_russh_exec_upload((TermoRusshSession *)s, command,
                                   (TermoRusshPullCallback)pull, userdata,
                                   exit_code, err, errlen);
}

int termo_ssh_exec_stream(TermoSSHSession *s, const char *command,
                          TermoSSHDataCallback on_data, void *userdata,
                          char *err, int errlen) {
    return termo_russh_exec_stream((TermoRusshSession *)s, command,
                                   (TermoRusshDataCallback)on_data, userdata,
                                   err, errlen);
}

// ── 交互式 shell ────────────────────────────────────────────────────────────

TermoSSHShell *termo_ssh_shell_open(TermoSSHSession *s, int cols, int rows,
                                    TermoSSHDataCallback on_data,
                                    TermoSSHClosedCallback on_closed, void *userdata,
                                    char *err, int errlen) {
    return (TermoSSHShell *)termo_russh_shell_open((TermoRusshSession *)s, cols, rows,
                                                   (TermoRusshDataCallback)on_data,
                                                   (TermoRusshClosedCallback)on_closed,
                                                   userdata, err, errlen);
}

long termo_ssh_shell_write(TermoSSHShell *sh, const char *buf, int len) {
    return termo_russh_shell_write((TermoRusshShell *)sh, buf, len);
}

int termo_ssh_shell_resize(TermoSSHShell *sh, int cols, int rows) {
    return termo_russh_shell_resize((TermoRusshShell *)sh, cols, rows);
}

void termo_ssh_shell_close(TermoSSHShell *sh) {
    termo_russh_shell_close((TermoRusshShell *)sh);
}

// ── 端口转发 ────────────────────────────────────────────────────────────────

TermoSSHForward *termo_ssh_forward_open(TermoSSHSession *s, int kind,
                                        const char *bind_addr, int listen_port,
                                        const char *dest_host, int dest_port,
                                        TermoSSHForwardStateCallback on_state, void *userdata,
                                        char *err, int errlen) {
    return (TermoSSHForward *)termo_russh_forward_open((TermoRusshSession *)s, kind,
                                                       bind_addr, listen_port, dest_host, dest_port,
                                                       (TermoRusshForwardStateCallback)on_state, userdata,
                                                       err, errlen);
}

void termo_ssh_forward_close(TermoSSHForward *f) {
    termo_russh_forward_close((TermoRusshForward *)f);
}

// ── SFTP（旧 ABI 首参为会话，russh 只需 sftp——适配层剥掉）────────────────────

void *termo_sftp_init(TermoSSHSession *s) {
    char err[256];
    return termo_russh_sftp_init((TermoRusshSession *)s, err, (int)sizeof(err));
}

void termo_sftp_shutdown(void *sftp) {
    termo_russh_sftp_shutdown((TermoRusshSftp *)sftp);
}

int termo_sftp_last_errno(void *sftp) {
    return termo_russh_sftp_last_errno((TermoRusshSftp *)sftp);
}

int termo_sftp_stat(TermoSSHSession *s, void *sftp, const char *path, int follow, TermoSFTPAttrs *out) {
    (void)s;
    return termo_russh_sftp_stat((TermoRusshSftp *)sftp, path, follow, (TermoRusshSFTPAttrs *)out);
}

int termo_sftp_setstat_perm(TermoSSHSession *s, void *sftp, const char *path, unsigned int mode) {
    (void)s;
    return termo_russh_sftp_setstat_perm((TermoRusshSftp *)sftp, path, mode);
}

int termo_sftp_mkdir(TermoSSHSession *s, void *sftp, const char *path) {
    (void)s;
    return termo_russh_sftp_mkdir((TermoRusshSftp *)sftp, path);
}

int termo_sftp_rmdir(TermoSSHSession *s, void *sftp, const char *path) {
    (void)s;
    return termo_russh_sftp_rmdir((TermoRusshSftp *)sftp, path);
}

int termo_sftp_unlink(TermoSSHSession *s, void *sftp, const char *path) {
    (void)s;
    return termo_russh_sftp_unlink((TermoRusshSftp *)sftp, path);
}

int termo_sftp_rename(TermoSSHSession *s, void *sftp, const char *from, const char *to, int overwrite) {
    (void)s;
    return termo_russh_sftp_rename((TermoRusshSftp *)sftp, from, to, overwrite);
}

int termo_sftp_realpath(TermoSSHSession *s, void *sftp, const char *path, char *out, int out_cap) {
    (void)s;
    return termo_russh_sftp_realpath((TermoRusshSftp *)sftp, path, out, out_cap);
}

void *termo_sftp_open(TermoSSHSession *s, void *sftp, const char *path, unsigned int pflags) {
    (void)s;
    return termo_russh_sftp_open((TermoRusshSftp *)sftp, path, pflags);
}

void *termo_sftp_opendir(TermoSSHSession *s, void *sftp, const char *path) {
    (void)s;
    return termo_russh_sftp_opendir((TermoRusshSftp *)sftp, path);
}

int termo_sftp_fstat(void *handle, TermoSFTPAttrs *out) {
    return termo_russh_sftp_fstat((TermoRusshSftpFile *)handle, (TermoRusshSFTPAttrs *)out);
}

long termo_sftp_read(void *handle, unsigned long long offset, char *buf, int len) {
    return (long)termo_russh_sftp_read((TermoRusshSftpFile *)handle, offset, buf, len);
}

long termo_sftp_write(void *handle, unsigned long long offset, const char *buf, int len) {
    return (long)termo_russh_sftp_write((TermoRusshSftpFile *)handle, offset, buf, len);
}

int termo_sftp_readdir(void *handle, char *name_buf, int name_cap, TermoSFTPAttrs *out) {
    return termo_russh_sftp_readdir((TermoRusshSftpFile *)handle, name_buf, name_cap, (TermoRusshSFTPAttrs *)out);
}

void termo_sftp_close(void *handle) {
    termo_russh_sftp_close((TermoRusshSftpFile *)handle);
}

// ── 密钥工具 ────────────────────────────────────────────────────────────────

int termo_key_generate(int type, const char *comment, const char *passphrase,
                       char *out_priv, int priv_cap, char *out_pub, int pub_cap,
                       char *out_fp, int fp_cap, char *err, int errlen) {
    return termo_russh_key_generate(type, comment, passphrase, out_priv, priv_cap,
                                    out_pub, pub_cap, out_fp, fp_cap, err, errlen);
}

int termo_key_pubkey_from_private(const char *priv_path, const char *passphrase,
                                  char *out_pub, int pub_cap, int *out_type, int *out_encrypted) {
    return termo_russh_key_pubkey_from_private(priv_path, passphrase, out_pub, pub_cap,
                                               out_type, out_encrypted);
}

int termo_key_fingerprint(const char *pub_line, char *out_fp, int fp_cap) {
    return termo_russh_key_fingerprint(pub_line, out_fp, fp_cap);
}
