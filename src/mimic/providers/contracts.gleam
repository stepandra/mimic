import gleam/option.{type Option}
import mimic/auth.{type Credential}
import mimic/types.{type Header}

/// No upstream bodies, exception strings, URLs or credentials in public errors.
pub type Reason {
  Unsupported
  InvalidConfiguration
  CredentialUnavailable
  ReauthorizationRequired
  NoAccount
  Quota
  Unavailable
  InvalidResponse
  Persistence
  Cancelled
}

pub type Delivery {
  /// The adapter guarantees no request bytes were transmitted.
  NotSent
  /// The adapter guarantees the upstream rejected without executing the request.
  Rejected
  /// Some bytes may have been sent. Never automatically replay.
  Uncertain
  /// Headers or body have been returned to the caller. Never replay.
  Started
}

pub type Failure {
  Failure(reason: Reason, delivery: Delivery, retry_after_ms: Option(Int))
}

pub type Mode {
  Buffered
  Streaming
}

pub type Capability {
  Buffer
  Stream
  Tools
  Images
  Audio
  Continuation
  WebSocket
}

pub type Request {
  Request(
    provider: String,
    auth_mode: String,
    model: String,
    protocol: String,
    operation: String,
    mode: Mode,
    required: List(Capability),
    session: String,
    /// Continuations must pin the account that created upstream state.
    pinned_account: Option(String),
    body: String,
  )
}

pub type Context {
  Context(
    provider: String,
    auth_mode: String,
    account: String,
    origin: String,
    /// Opaque, credential-scoped identifier. Never reuse across accounts.
    session_key: String,
    credential: AuthMaterial,
  )
}

/// API keys have neither expiry nor refresh tokens.
pub type AuthMaterial {
  ApiKey(String)
  OAuth(OAuthData)
  /// A permanent session credential, not an API key or expiring OAuth grant.
  /// Profile/quota enrichment does not rotate or refresh this token.
  SessionToken(token: String, private_metadata: List(#(String, String)))
}

/// Private provider identity data, atomically persisted with rotated tokens.
/// Never include this envelope in management responses or diagnostics.
pub type OAuthData {
  OAuthData(credential: Credential, private_metadata: List(#(String, String)))
}

pub type Opened(handle) {
  Opened(status: Int, headers: List(Header), handle: handle)
}

/// Trusted adapter callbacks run in the execution process. Handles/sockets must
/// be owned by that process, not a global connection pool. No callback may log
/// Context or Request. Origin changes and redirects are forbidden.
pub type Adapter(handle) {
  Adapter(
    open: fn(Context, Request) -> Result(Opened(handle), Failure),
    next: fn(handle) -> Result(Option(#(BitArray, handle)), Failure),
    cancel: fn(handle) -> Nil,
    /// Only explicit, known-safe upstream rejections permit retry.
    rejection: fn(Int, List(Header)) -> Option(Failure),
  )
}

/// A connection remains leased to one authenticated client/model until closed.
/// Open performs only the handshake; send is never retried, even before output.
/// Receive is a bounded poll: None is idle, not EOF. EOF is an error.
pub type SessionAdapter(handle) {
  SessionAdapter(
    open: fn(Context, Request) -> Result(Opened(handle), Failure),
    send: fn(handle, Request) -> Result(handle, Failure),
    receive: fn(handle) -> Result(#(Option(String), handle), Failure),
    cancel: fn(handle) -> Nil,
  )
}

pub type RefreshFailure {
  InvalidGrant
  /// A recognized provider rejection, not merely an error-looking body.
  RefreshRateLimited(retry_after_ms: Int)
  /// Adapter proves no request was sent or no grant execution occurred.
  RefreshRetryable
  /// Outcome may conceal rotation (timeout, invalid success, exception).
  RefreshUnavailable
  RefreshUnsupported
}

pub type Refresh {
  Refresh(fn(OAuthData, Int) -> Result(OAuthData, RefreshFailure))
}

pub type HttpProtocol {
  Http1
  /// Representable so unsupported transport requirements fail before I/O.
  Http2
}

pub type BinaryMedia {
  ConnectProto
  Proto
}

/// A SECRET in-memory request plan, never a Capture or diagnostic artifact.
/// Token material can occur inside the binary body as well as headers.
/// Provider code owns Connect envelopes/protobuf/EOS; runtime owns HTTP bytes.
pub type HttpRequest {
  HttpRequest(
    endpoint: String,
    method: String,
    target: String,
    headers: List(Header),
    body: BitArray,
    protocol: HttpProtocol,
    media: BinaryMedia,
  )
}
