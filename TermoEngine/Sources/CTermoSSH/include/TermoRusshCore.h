//  Rust SSH 引擎（russh 0.63.3）的 C 接口——与 TermoSSHCore.h 语义逐一对齐。
//  由 Engine/TermoSSH staticlib（libtermo_ssh.a）导出；构建见 scripts/build-russh.sh。
//  Swift 侧不直接调用本头；经 TermoSSHDispatch.c 按后端开关分发（termo_ssh_* 不变）。
//
//  约定（与 TermoSSHCore.h 一致）：
//  - 返回 int 的 SFTP 函数：0=成功；>0 且 <0xF000 = SFTP 状态码；≥0xF000 = 传输/内部错误
//  - 字符串缓冲超长截断且 NUL 结尾（exec2 的 out/errout 为二进制安全，按 *out_len 取用）
//  - known_hosts 校验：仅明确匹配才允许认证；未知/变更/撤销/读取失败均拒绝（HOSTKEY_*）
#ifndef TERMO_RUSSH_CORE_H
#define TERMO_RUSSH_CORE_H

#include <stdbool.h>
#include "TermoConnectionOptions.h"

#ifdef __cplusplus
extern "C" {
#endif

// ── Rust 后端直连接口（分发层以下仅供 TermoSSHDispatch.c 使用）────────────────

/// russh 后端版本（静态字符串，勿释放）。
const char *termo_russh_backend_version(void);

typedef struct TermoRusshSession TermoRusshSession;
typedef struct TermoRusshShell TermoRusshShell;
typedef struct TermoRusshForward TermoRusshForward;
typedef struct TermoRusshSftp TermoRusshSftp;
typedef struct TermoRusshSftpFile TermoRusshSftpFile;

/// 一次性连接/认证/exec 探针。返回 0=成功、1=认证被拒、-1=错误。
int termo_russh_probe(const char *host, int port, const char *user,
                      const char *password, const char *key_path, const char *key_passphrase,
                      char *fingerprint_out, int fingerprint_cap, int *exit_code_out,
                      int timeout_ms, char *err, int errlen);

/// 连接+握手+认证。认证前必须匹配 known_hosts；不传信任路径也不能跳过校验。
TermoRusshSession *termo_russh_session_open(const char *host, int port,
                                            const char *user, const char *password,
                                            const char *key_path, const char *key_passphrase,
                                            const char *real_known_hosts, const char *session_known_hosts,
                                            char *fingerprint_out, int fingerprint_cap,
                                            int timeout_ms, const TermoConnectionOptions *options, char *err, int errlen);
/// Shared transport; each returned operation has its own cancellation state.
TermoRusshSession *termo_russh_session_fork(TermoRusshSession *s);
bool termo_russh_session_is_disconnected(TermoRusshSession *s);
void termo_russh_session_disconnect(TermoRusshSession *s);

void termo_russh_session_cancel(TermoRusshSession *s);
/// 会话是否已失效（超时/取消后粘住）。失效会话不可归还复用，应 close 重建。
bool termo_russh_session_is_poisoned(TermoRusshSession *s);
void termo_russh_session_close(TermoRusshSession *s);
const char *termo_russh_session_sha256(TermoRusshSession *s);
const char *termo_russh_session_md5(TermoRusshSession *s);

/// exec 带 stdin + 整体超时 + 可取消。返回 0=完成 1=超时 2=取消 -1=错误。
int termo_russh_exec2(TermoRusshSession *s, const char *command,
                      const char *stdin_bytes, int stdin_len,
                      char *out, int out_cap, int *out_len,
                      char *errout, int errout_cap, int *err_len,
                      int *exit_code, int timeout_ms, char *err, int errlen);

/// stdout/stderr callback (is_stderr: 0/1), valid only until this blocking call returns.
typedef void (*TermoRusshExecObserver)(void *userdata, int is_stderr, const char *bytes, int len);
int termo_russh_exec_observed(TermoRusshSession *s, const char *command,
    TermoRusshExecObserver on_data, void *userdata, int *exit_code,
    int timeout_ms, char *err, int errlen);


typedef void (*TermoRusshDataCallback)(void *userdata, const char *bytes, int len);
typedef int  (*TermoRusshPullCallback)(void *userdata, char *buf, int cap);

/// 流式上传 exec。返回 0=完成 / 1=被取消 / -1=错误。
int termo_russh_exec_upload(TermoRusshSession *s, const char *command,
                            TermoRusshPullCallback pull, void *userdata,
                            int *exit_code, char *err, int errlen);
/// 流式 exec：stdout 增量回调。返回 0=结束/被取消、-1=错误。
int termo_russh_exec_stream(TermoRusshSession *s, const char *command,
                            TermoRusshDataCallback on_data, void *userdata,
                            char *err, int errlen);

/// One-shot token, independent of shared SSH sessions. Retain until all calls return.
typedef struct TermoRusshConnectionCancellation TermoRusshConnectionCancellation;
TermoRusshConnectionCancellation *termo_russh_connection_cancellation_new(void);
void termo_russh_connection_cancellation_cancel(TermoRusshConnectionCancellation *token);
void termo_russh_connection_cancellation_free(TermoRusshConnectionCancellation *token);

/// 主机密钥扫描结果（与 TermoSSHCore.h 的 TermoHostKeyScan 字段一一对应）。
typedef struct {
    int status;          // 0=匹配 1=未知 2=不匹配 3=读取/解析失败 4=撤销 5=不支持 -1=握手失败
    char sha256[80];     // "SHA256:base64"
    char md5[64];        // "ab:cd:…"
    char line[1024];     // known_hosts 信任行
} TermoRusshHostKeyScan;

/// 扫描主机密钥（仅握手不认证）。结果写 *out；返回 0=完成 -1=失败。
int termo_russh_scan_hostkey(const char *host, int port,
                             const char *real_known_hosts, const char *session_known_hosts,
                             TermoRusshConnectionCancellation *token, const TermoConnectionOptions *options, TermoRusshHostKeyScan *out);

/// Stages 1=DNS, 2=TCP, 3=handshake, 4=authentication, 5=complete.
/// Blocking; callbacks/userdata are only used before return. Cancel from another thread.
typedef void (*TermoRusshStageCallback)(void *userdata, int stage, int ok, const char *message);
void termo_russh_test(const char *host, int port, const char *user,
    const char *password, const char *key_path, const char *key_passphrase,
    const char *real_known_hosts, const char *session_known_hosts,
    TermoRusshConnectionCancellation *token, const TermoConnectionOptions *options, TermoRusshStageCallback on_stage, void *userdata);

// ── 交互式 shell（PTY）──────────────────────────────────────────────────────
typedef void (*TermoRusshClosedCallback)(void *userdata, int exit_code);

/// command 非空 → PTY+exec 该命令（如 tmux attach，不经登录 shell、无 history 污染）；
/// NULL/空串 → 交互 shell。
TermoRusshShell *termo_russh_shell_open(TermoRusshSession *s, int cols, int rows,
                                        const char *command,
                                        TermoRusshDataCallback on_data,
                                        TermoRusshClosedCallback on_closed, void *userdata,
                                        char *err, int errlen);
long termo_russh_shell_write(TermoRusshShell *sh, const char *buf, int len);
int  termo_russh_shell_resize(TermoRusshShell *sh, int cols, int rows);
void termo_russh_shell_close(TermoRusshShell *sh);

// ── 端口转发（0=-L 1=-R 2=-D）───────────────────────────────────────────────
typedef void (*TermoRusshForwardStateCallback)(void *userdata, int ok, const char *message);

TermoRusshForward *termo_russh_forward_open(TermoRusshSession *s, int kind,
                                            const char *bind_addr, int listen_port,
                                            const char *dest_host, int dest_port,
                                            TermoRusshForwardStateCallback on_state, void *userdata,
                                            char *err, int errlen);
void termo_russh_forward_close(TermoRusshForward *f);

// ── SFTP ────────────────────────────────────────────────────────────────────
typedef struct {
    int has_size, has_perm, has_mtime;
    unsigned long long size;
    unsigned int permissions;
    unsigned int mtime;
} TermoRusshSFTPAttrs;

TermoRusshSftp *termo_russh_sftp_init(TermoRusshSession *s, char *err, int errlen);
void termo_russh_sftp_shutdown(TermoRusshSftp *sftp);
int  termo_russh_sftp_last_errno(TermoRusshSftp *sftp);
void termo_russh_sftp_set_last(TermoRusshSftp *sftp, int code);

int   termo_russh_sftp_stat(TermoRusshSftp *sftp, const char *path, int follow, TermoRusshSFTPAttrs *out);
int   termo_russh_sftp_setstat_perm(TermoRusshSftp *sftp, const char *path, unsigned int mode);
int   termo_russh_sftp_mkdir(TermoRusshSftp *sftp, const char *path);
int   termo_russh_sftp_rmdir(TermoRusshSftp *sftp, const char *path);
int   termo_russh_sftp_unlink(TermoRusshSftp *sftp, const char *path);
/// overwrite=1 uses posix-rename; errors are returned without deleting the destination or retrying.
int   termo_russh_sftp_rename(TermoRusshSftp *sftp, const char *from, const char *to, int overwrite);
int   termo_russh_sftp_realpath(TermoRusshSftp *sftp, const char *path, char *out, int out_cap);

TermoRusshSftpFile *termo_russh_sftp_open(TermoRusshSftp *sftp, const char *path, unsigned int pflags);
TermoRusshSftpFile *termo_russh_sftp_opendir(TermoRusshSftp *sftp, const char *path);
int   termo_russh_sftp_fstat(TermoRusshSftpFile *handle, TermoRusshSFTPAttrs *out);
long long termo_russh_sftp_read(TermoRusshSftpFile *handle, unsigned long long offset, char *buf, int len);
long long termo_russh_sftp_write(TermoRusshSftpFile *handle, unsigned long long offset, const char *buf, int len);
int   termo_russh_sftp_readdir(TermoRusshSftpFile *handle, char *name_buf, int name_cap, TermoRusshSFTPAttrs *out);
void  termo_russh_sftp_close(TermoRusshSftpFile *handle);

// ── 密钥工具 ────────────────────────────────────────────────────────────────
int termo_russh_key_generate(int type, const char *comment, const char *passphrase,
                             char *out_priv, int priv_cap, char *out_pub, int pub_cap,
                             char *out_fp, int fp_cap, char *err, int errlen);
int termo_russh_key_pubkey_from_private(const char *priv_path, const char *passphrase,
                                        char *out_pub, int pub_cap, int *out_type, int *out_encrypted);
int termo_russh_key_fingerprint(const char *pub_line, char *out_fp, int fp_cap);

#ifdef __cplusplus
}
#endif
#endif // TERMO_RUSSH_CORE_H
