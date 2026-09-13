//  SSH 引擎后端分发层：Swift 侧调用符号不变（termo_ssh_* / termo_sftp_* / termo_key_*），
//  由本文件按开关路由到 russh（termo_russh_*）或 libssh2 旧引擎（termo_*_legacy_*）。
//
//  - 默认 russh（dev 分支）；可用 UserDefaults("ssh.useLibssh2")=YES 或
//    termo_ssh_set_backend(0) 回退旧引擎（两套实现共存，soak 稳定后再移除 legacy）。
//  - 语义对齐承诺见 TermoRusshCore.h 头注；差异点：
//    · termo_ssh_exec 的输出缓冲由分发层补 NUL（russh 侧为二进制安全）
//    · termo_ssh_test 的 stage1/2 由分发层自测（DNS/TCP），russh 一次完成握手+认证
#include "TermoSSHCore.h"
#include "TermoRusshCore.h"
#include "TermoSSHLegacy.h"

#include <stdio.h>
#include <netdb.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int g_termo_use_russh = 1;   // dev 分支默认 russh

void termo_ssh_set_backend(int use_russh) { g_termo_use_russh = use_russh ? 1 : 0; }
int  termo_ssh_get_backend(void)          { return g_termo_use_russh; }

// ── 会话 ────────────────────────────────────────────────────────────────────

TermoSSHSession *termo_ssh_open(const char *host, int port,
                                const char *user, const char *password,
                                const char *key_path, const char *key_passphrase,
                                const char *real_known_hosts, const char *session_known_hosts,
                                char *err, int errlen) {
    if (g_termo_use_russh) {
        return (TermoSSHSession *)termo_russh_session_open(
            host, port, user, password, key_path, key_passphrase,
            real_known_hosts, session_known_hosts,
            NULL, 0, 20000, err, errlen);
    }
    return termo_ssh_legacy_open(host, port, user, password, key_path, key_passphrase,
                                 real_known_hosts, session_known_hosts, err, errlen);
}

const char *termo_ssh_session_sha256(TermoSSHSession *s) {
    return g_termo_use_russh ? termo_russh_session_sha256((TermoRusshSession *)s)
                             : termo_ssh_legacy_session_sha256(s);
}

const char *termo_ssh_session_md5(TermoSSHSession *s) {
    return g_termo_use_russh ? termo_russh_session_md5((TermoRusshSession *)s)
                             : termo_ssh_legacy_session_md5(s);
}

void termo_ssh_cancel(TermoSSHSession *s) {
    if (g_termo_use_russh) termo_russh_session_cancel((TermoRusshSession *)s);
    else termo_ssh_legacy_cancel(s);
}

void termo_ssh_close(TermoSSHSession *s) {
    if (g_termo_use_russh) termo_russh_session_close((TermoRusshSession *)s);
    else termo_ssh_legacy_close(s);
}

// ── 主机密钥扫描 ────────────────────────────────────────────────────────────

void termo_ssh_scan_hostkey(const char *host, int port,
                            const char *real_known_hosts, const char *session_known_hosts,
                            TermoHostKeyScan *out) {
    if (!out) return;
    if (g_termo_use_russh) {
        TermoRusshHostKeyScan scan;
        memset(&scan, 0, sizeof(scan));
        if (termo_russh_scan_hostkey(host, port, real_known_hosts, session_known_hosts, &scan) == 0) {
            memcpy(out, &scan, sizeof(scan));   // 字段布局一致
        } else {
            out->status = -1;
        }
        return;
    }
    termo_ssh_legacy_scan_hostkey(host, port, real_known_hosts, session_known_hosts, out);
}

// ── 分阶段测试连接（russh 路径：DNS/TCP 自测 + 一次会话建立）────────────────

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
    if (!g_termo_use_russh) {
        termo_ssh_legacy_test(host, port, user, password, key_path, key_passphrase, on_stage, userdata);
        return;
    }
    char msg[512];
    // stage 1/2：DNS + TCP（分发层自测，失败即止）
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
    if (g_termo_use_russh) {
        int out_len = 0, err_len = 0;
        int rc = termo_russh_exec2((TermoRusshSession *)s, command,
                                   NULL, 0,
                                   out, out_cap > 0 ? out_cap - 1 : 0, &out_len,
                                   errout, errout_cap > 0 ? errout_cap - 1 : 0, &err_len,
                                   exit_code, 20000, err, errlen);
        if (rc == 0) {
            if (out && out_cap > 0) out[out_len] = '\0';
            if (errout && errout_cap > 0) errout[err_len < errout_cap ? err_len : errout_cap - 1] = '\0';
            return 0;
        }
        if (rc == 1 || rc == 2) return -1;   // 超时/取消按旧口径归为错误（旧实现无此区分）
        return -1;
    }
    return termo_ssh_legacy_exec(s, command, out, out_cap, errout, errout_cap, exit_code, err, errlen);
}

int termo_ssh_exec2(TermoSSHSession *s, const char *command,
                    const char *stdin_bytes, int stdin_len,
                    char *out, int out_cap, int *out_len,
                    char *errout, int errout_cap, int *err_len,
                    int *exit_code, int timeout_ms, char *err, int errlen) {
    if (g_termo_use_russh) {
        return termo_russh_exec2((TermoRusshSession *)s, command, stdin_bytes, stdin_len,
                                 out, out_cap, out_len, errout, errout_cap, err_len,
                                 exit_code, timeout_ms, err, errlen);
    }
    return termo_ssh_legacy_exec2(s, command, stdin_bytes, stdin_len, out, out_cap, out_len,
                                  errout, errout_cap, err_len, exit_code, timeout_ms, err, errlen);
}

int termo_ssh_exec_upload(TermoSSHSession *s, const char *command,
                          TermoSSHPullCallback pull, void *userdata,
                          int *exit_code, char *err, int errlen) {
    if (g_termo_use_russh) {
        return termo_russh_exec_upload((TermoRusshSession *)s, command,
                                       (TermoRusshPullCallback)pull, userdata,
                                       exit_code, err, errlen);
    }
    return termo_ssh_legacy_exec_upload(s, command, pull, userdata, exit_code, err, errlen);
}

int termo_ssh_exec_stream(TermoSSHSession *s, const char *command,
                          TermoSSHDataCallback on_data, void *userdata,
                          char *err, int errlen) {
    if (g_termo_use_russh) {
        return termo_russh_exec_stream((TermoRusshSession *)s, command,
                                       (TermoRusshDataCallback)on_data, userdata,
                                       err, errlen);
    }
    return termo_ssh_legacy_exec_stream(s, command, on_data, userdata, err, errlen);
}

// ── 交互式 shell ────────────────────────────────────────────────────────────

TermoSSHShell *termo_ssh_shell_open(TermoSSHSession *s, int cols, int rows,
                                    TermoSSHDataCallback on_data,
                                    TermoSSHClosedCallback on_closed, void *userdata,
                                    char *err, int errlen) {
    if (g_termo_use_russh) {
        return (TermoSSHShell *)termo_russh_shell_open((TermoRusshSession *)s, cols, rows,
                                                       (TermoRusshDataCallback)on_data,
                                                       (TermoRusshClosedCallback)on_closed,
                                                       userdata, err, errlen);
    }
    return termo_ssh_legacy_shell_open(s, cols, rows, on_data, on_closed, userdata, err, errlen);
}

long termo_ssh_shell_write(TermoSSHShell *sh, const char *buf, int len) {
    if (g_termo_use_russh) return termo_russh_shell_write((TermoRusshShell *)sh, buf, len);
    return termo_ssh_legacy_shell_write(sh, buf, len);
}

int termo_ssh_shell_resize(TermoSSHShell *sh, int cols, int rows) {
    if (g_termo_use_russh) return termo_russh_shell_resize((TermoRusshShell *)sh, cols, rows);
    return termo_ssh_legacy_shell_resize(sh, cols, rows);
}

void termo_ssh_shell_close(TermoSSHShell *sh) {
    if (g_termo_use_russh) termo_russh_shell_close((TermoRusshShell *)sh);
    else termo_ssh_legacy_shell_close(sh);
}

// ── 端口转发 ────────────────────────────────────────────────────────────────

TermoSSHForward *termo_ssh_forward_open(TermoSSHSession *s, int kind,
                                        const char *bind_addr, int listen_port,
                                        const char *dest_host, int dest_port,
                                        TermoSSHForwardStateCallback on_state, void *userdata,
                                        char *err, int errlen) {
    if (g_termo_use_russh) {
        return (TermoSSHForward *)termo_russh_forward_open((TermoRusshSession *)s, kind,
                                                           bind_addr, listen_port, dest_host, dest_port,
                                                           (TermoRusshForwardStateCallback)on_state, userdata,
                                                           err, errlen);
    }
    return termo_ssh_legacy_forward_open(s, kind, bind_addr, listen_port, dest_host, dest_port,
                                         on_state, userdata, err, errlen);
}

void termo_ssh_forward_close(TermoSSHForward *f) {
    if (g_termo_use_russh) termo_russh_forward_close((TermoRusshForward *)f);
    else termo_ssh_legacy_forward_close(f);
}

// ── SFTP（legacy 首参为会话，russh 只需 sftp——分发层剥掉）────────────────────

void *termo_sftp_init(TermoSSHSession *s) {
    if (g_termo_use_russh) {
        char err[256];
        return termo_russh_sftp_init((TermoRusshSession *)s, err, (int)sizeof(err));
    }
    return termo_sftp_legacy_init(s);
}

void termo_sftp_shutdown(void *sftp) {
    if (g_termo_use_russh) termo_russh_sftp_shutdown((TermoRusshSftp *)sftp);
    else termo_sftp_legacy_shutdown(sftp);
}

int termo_sftp_last_errno(void *sftp) {
    if (g_termo_use_russh) return termo_russh_sftp_last_errno((TermoRusshSftp *)sftp);
    return termo_sftp_legacy_last_errno(sftp);
}

int termo_sftp_stat(TermoSSHSession *s, void *sftp, const char *path, int follow, TermoSFTPAttrs *out) {
    (void)s;
    if (g_termo_use_russh) return termo_russh_sftp_stat((TermoRusshSftp *)sftp, path, follow, (TermoRusshSFTPAttrs *)out);
    return termo_sftp_legacy_stat(s, sftp, path, follow, out);
}

int termo_sftp_setstat_perm(TermoSSHSession *s, void *sftp, const char *path, unsigned int mode) {
    (void)s;
    if (g_termo_use_russh) return termo_russh_sftp_setstat_perm((TermoRusshSftp *)sftp, path, mode);
    return termo_sftp_legacy_setstat_perm(s, sftp, path, mode);
}

int termo_sftp_mkdir(TermoSSHSession *s, void *sftp, const char *path) {
    (void)s;
    if (g_termo_use_russh) return termo_russh_sftp_mkdir((TermoRusshSftp *)sftp, path);
    return termo_sftp_legacy_mkdir(s, sftp, path);
}

int termo_sftp_rmdir(TermoSSHSession *s, void *sftp, const char *path) {
    (void)s;
    if (g_termo_use_russh) return termo_russh_sftp_rmdir((TermoRusshSftp *)sftp, path);
    return termo_sftp_legacy_rmdir(s, sftp, path);
}

int termo_sftp_unlink(TermoSSHSession *s, void *sftp, const char *path) {
    (void)s;
    if (g_termo_use_russh) return termo_russh_sftp_unlink((TermoRusshSftp *)sftp, path);
    return termo_sftp_legacy_unlink(s, sftp, path);
}

int termo_sftp_rename(TermoSSHSession *s, void *sftp, const char *from, const char *to, int overwrite) {
    (void)s;
    if (g_termo_use_russh) return termo_russh_sftp_rename((TermoRusshSftp *)sftp, from, to, overwrite);
    return termo_sftp_legacy_rename(s, sftp, from, to, overwrite);
}

int termo_sftp_realpath(TermoSSHSession *s, void *sftp, const char *path, char *out, int out_cap) {
    (void)s;
    if (g_termo_use_russh) return termo_russh_sftp_realpath((TermoRusshSftp *)sftp, path, out, out_cap);
    return termo_sftp_legacy_realpath(s, sftp, path, out, out_cap);
}

void *termo_sftp_open(TermoSSHSession *s, void *sftp, const char *path, unsigned int pflags) {
    (void)s;
    if (g_termo_use_russh) return termo_russh_sftp_open((TermoRusshSftp *)sftp, path, pflags);
    return termo_sftp_legacy_open(s, sftp, path, pflags);
}

void *termo_sftp_opendir(TermoSSHSession *s, void *sftp, const char *path) {
    (void)s;
    if (g_termo_use_russh) return termo_russh_sftp_opendir((TermoRusshSftp *)sftp, path);
    return termo_sftp_legacy_opendir(s, sftp, path);
}

int termo_sftp_fstat(void *handle, TermoSFTPAttrs *out) {
    if (g_termo_use_russh) return termo_russh_sftp_fstat((TermoRusshSftpFile *)handle, (TermoRusshSFTPAttrs *)out);
    return termo_sftp_legacy_fstat(handle, out);
}

long termo_sftp_read(void *handle, unsigned long long offset, char *buf, int len) {
    if (g_termo_use_russh) return (long)termo_russh_sftp_read((TermoRusshSftpFile *)handle, offset, buf, len);
    return termo_sftp_legacy_read(handle, offset, buf, len);
}

long termo_sftp_write(void *handle, unsigned long long offset, const char *buf, int len) {
    if (g_termo_use_russh) return (long)termo_russh_sftp_write((TermoRusshSftpFile *)handle, offset, buf, len);
    return termo_sftp_legacy_write(handle, offset, buf, len);
}

int termo_sftp_readdir(void *handle, char *name_buf, int name_cap, TermoSFTPAttrs *out) {
    if (g_termo_use_russh) return termo_russh_sftp_readdir((TermoRusshSftpFile *)handle, name_buf, name_cap, (TermoRusshSFTPAttrs *)out);
    return termo_sftp_legacy_readdir(handle, name_buf, name_cap, out);
}

void termo_sftp_close(void *handle) {
    if (g_termo_use_russh) termo_russh_sftp_close((TermoRusshSftpFile *)handle);
    else termo_sftp_legacy_close(handle);
}

// ── 密钥工具 ────────────────────────────────────────────────────────────────

int termo_key_generate(int type, const char *comment, const char *passphrase,
                       char *out_priv, int priv_cap, char *out_pub, int pub_cap,
                       char *out_fp, int fp_cap, char *err, int errlen) {
    if (g_termo_use_russh) {
        return termo_russh_key_generate(type, comment, passphrase, out_priv, priv_cap,
                                        out_pub, pub_cap, out_fp, fp_cap, err, errlen);
    }
    return termo_key_legacy_generate(type, comment, passphrase, out_priv, priv_cap,
                                     out_pub, pub_cap, out_fp, fp_cap, err, errlen);
}

int termo_key_pubkey_from_private(const char *priv_path, const char *passphrase,
                                  char *out_pub, int pub_cap, int *out_type, int *out_encrypted) {
    if (g_termo_use_russh) {
        return termo_russh_key_pubkey_from_private(priv_path, passphrase, out_pub, pub_cap,
                                                   out_type, out_encrypted);
    }
    return termo_key_legacy_pubkey_from_private(priv_path, passphrase, out_pub, pub_cap,
                                                out_type, out_encrypted);
}

int termo_key_fingerprint(const char *pub_line, char *out_fp, int fp_cap) {
    if (g_termo_use_russh) return termo_russh_key_fingerprint(pub_line, out_fp, fp_cap);
    return termo_key_legacy_fingerprint(pub_line, out_fp, fp_cap);
}
