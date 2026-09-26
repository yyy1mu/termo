//  SSH 引擎（russh）适配层：Swift 侧调用符号保持 termo_ssh_* / termo_sftp_* / termo_key_*，
//  本文件把旧引擎 ABI 1:1 前转 russh（termo_russh_*）；libssh2 实现已移除。
//
//  语义对齐承诺见 TermoRusshCore.h 头注；差异点：
//  · termo_ssh_exec 的输出缓冲由适配层补 NUL（russh 侧为二进制安全）
//  · 连接诊断由 russh 在实际连接上报告阶段，并支持独立取消
#include "TermoSSHCore.h"
#include "TermoRusshCore.h"

#include <stdio.h>
#include <string.h>

// ── 会话 ────────────────────────────────────────────────────────────────────

TermoSSHSession *termo_ssh_open(const char *host, int port,
                                const char *user, const char *password,
                                const char *key_path, const char *key_passphrase,
                                const char *real_known_hosts, const char *session_known_hosts,
                                const TermoConnectionOptions *options, char *err, int errlen) {
    return (TermoSSHSession *)termo_russh_session_open(
        host, port, user, password, key_path, key_passphrase,
        real_known_hosts, session_known_hosts,
        NULL, 0, 0, options, err, errlen);
}

TermoSSHSession *termo_ssh_session_fork(TermoSSHSession *s) {
    return (TermoSSHSession *)termo_russh_session_fork((TermoRusshSession *)s);
}

bool termo_ssh_session_is_disconnected(TermoSSHSession *s) {
    return termo_russh_session_is_disconnected((TermoRusshSession *)s);
}

void termo_ssh_session_disconnect(TermoSSHSession *s) {
    termo_russh_session_disconnect((TermoRusshSession *)s);
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
                            TermoSSHConnectionCancellation *token, const TermoConnectionOptions *options, TermoHostKeyScan *out) {
    if (!out) return;
    TermoRusshHostKeyScan scan;
    memset(&scan, 0, sizeof(scan));
    if (termo_russh_scan_hostkey(host, port, real_known_hosts, session_known_hosts, (TermoRusshConnectionCancellation *)token, options, &scan) == 0) {
        memcpy(out, &scan, sizeof(scan));   // 字段布局一致
    } else {
        out->status = -1;
    }
}

// ── 连接诊断与取消 ─────────────────────────────────────────────────────────
TermoSSHConnectionCancellation *termo_ssh_connection_cancellation_new(void) {
    return (TermoSSHConnectionCancellation *)termo_russh_connection_cancellation_new();
}
void termo_ssh_connection_cancellation_cancel(TermoSSHConnectionCancellation *token) {
    termo_russh_connection_cancellation_cancel((TermoRusshConnectionCancellation *)token);
}
void termo_ssh_connection_cancellation_free(TermoSSHConnectionCancellation *token) {
    termo_russh_connection_cancellation_free((TermoRusshConnectionCancellation *)token);
}
void termo_ssh_test(const char *host, int port, const char *user,
                    const char *password, const char *key_path, const char *key_passphrase,
                    const char *real_known_hosts, const char *session_known_hosts,
                    TermoSSHConnectionCancellation *token, const TermoConnectionOptions *options, TermoSSHStageCallback on_stage, void *userdata) {
    termo_russh_test(host, port, user, password, key_path, key_passphrase,
                    real_known_hosts, session_known_hosts,
                    (TermoRusshConnectionCancellation *)token, options, on_stage, userdata);
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
                                    const char *command,
                                    TermoSSHDataCallback on_data,
                                    TermoSSHClosedCallback on_closed, void *userdata,
                                    char *err, int errlen) {
    return (TermoSSHShell *)termo_russh_shell_open((TermoRusshSession *)s, cols, rows, command,
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

int termo_ssh_exec_observed(TermoSSHSession *s, const char *command,
    TermoSSHExecObserver on_data, void *userdata, int *exit_code,
    int timeout_ms, char *err, int errlen) {
    return termo_russh_exec_observed((TermoRusshSession *)s, command,
        (TermoRusshExecObserver)on_data, userdata, exit_code, timeout_ms, err, errlen);
}
