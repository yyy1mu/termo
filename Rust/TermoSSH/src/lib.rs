//! Rust SSH backend proof of concept.
//!
//! This crate intentionally exposes only a stable C ABI probe for the first
//! milestone. The existing libssh2 backend remains the production path until
//! the Rust session, channel, and lifecycle adapters pass compatibility tests.

use std::ffi::c_char;

/// Returns the compiled russh backend version through a stable C ABI.
///
/// The returned pointer is static and must not be freed by the caller.
#[no_mangle]
pub extern "C" fn termo_russh_backend_version() -> *const c_char {
    c"russh-0.63.3".as_ptr()
}
