//  Rust SSH 引擎（russh 0.63.3）的 C 接口——与 libssh2 版 TermoSSHCore.h 语义逐一对齐。
//  由 Rust/TermoSSH staticlib（libtermo_ssh.a）导出；构建见 scripts/build-russh.sh。
//  Swift 侧不直接调用本头；经 TermoSSHDispatch.c 按后端开关分发（termo_ssh_* 不变）。
//
//  约定（与 libssh2 版一致）：
//  - 返回 int 的 SFTP 函数：0=成功；>0 且 <0xF000 = SFTP 状态码；≥0xF000 = 传输/内部错误
//  - 字符串缓冲超长截断且 NUL 结尾（exec2 的 out/errout 为二进制安全，按 *out_len 取用）
//  - known_hosts 校验：仅明确不匹配拒绝（err 以 HOSTKEY_MISMATCH 开头），未知/解析失败放行
#ifndef TERMO_RUSSH_CORE_H
#define TERMO_RUSSH_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

// ── 后端开关（分发层用）─────────────────────────────────────────────────────
/// 0=libssh2 旧引擎，1=russh。默认 1（dev 分支）；MAS/回退可在启动时设 0。
void termo_ssh_set_backend(int use_russh);
int  termo_ssh_get_backend(void);

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

/// 连接+握手+认证。known_hosts 两参数非空时认证前校验（仅明确不匹配拒绝）。
TermoRusshSession *termo_russh_session_open(const char *host, int port,
                                            const char *user, const char *password,
                                            const char *key_path, const char *key_passphrase,
                                            const char *real_known_hosts, const char *session_known_hosts,
                                            char *fingerprint_out, int fingerprint_cap,
                                            int timeout_ms, char *err, int errlen);
void termo_russh_session_cancel(TermoRusshSession *s);
void termo_russh_session_close(TermoRusshSession *s);
const char *termo_russh_session_sha256(TermoRusshSession *s);
const char *termo_russh_session_md5(TermoRusshSession *s);

/// exec 带 stdin + 整体超时 + 可取消。返回 0=完成 1=超时 2=取消 -1=错误。
int termo_russh_exec2(TermoRusshSession *s, const char *command,
                      const char *stdin_bytes, int stdin_len,
                      char *out, int out_cap, int *out_len,
                      char *errout, int errout_cap, int *err_len,
                      int *exit_code, int timeout_ms, char *err, int errlen);

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

/// 主机密钥扫描结果（与 libssh2 版 TermoHostKeyScan 字段一一对应）。
typedef struct {
    int status;          // 0=已知匹配 1=未知 2=不匹配(MITM) -1=失败
    char sha256[80];     // "SHA256:base64"
    char md5[64];        // "ab:cd:…"
    char line[1024];     // known_hosts 信任行
} TermoRusshHostKeyScan;

/// 扫描主机密钥（仅握手不认证）。结果写 *out；返回 0=完成 -1=失败。
int termo_russh_scan_hostkey(const char *host, int port,
                             const char *real_known_hosts, const char *session_known_hosts,
                             TermoRusshHostKeyScan *out);

// ── 交互式 shell（PTY）──────────────────────────────────────────────────────
typedef void (*TermoRusshClosedCallback)(void *userdata, int exit_code);

TermoRusshShell *termo_russh_shell_open(TermoRusshSession *s, int cols, int rows,
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
