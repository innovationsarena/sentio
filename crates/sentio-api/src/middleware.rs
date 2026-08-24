use std::net::{IpAddr, SocketAddr};

use axum::extract::{ConnectInfo, Request};
use axum::http::HeaderValue;
use axum::middleware::Next;
use axum::response::Response;
use tower_http::request_id::{MakeRequestId, RequestId};

use crate::errors::ApiError;
use crate::state::AppState;

// ──────────────────────────────────────────────────────────────────────────────
// Request ID generator
// ──────────────────────────────────────────────────────────────────────────────

#[derive(Clone)]
pub struct UuidRequestId;

impl MakeRequestId for UuidRequestId {
    fn make_request_id<B>(&mut self, _request: &axum::http::Request<B>) -> Option<RequestId> {
        let id = uuid::Uuid::new_v4().to_string();
        Some(RequestId::new(HeaderValue::from_str(&id).unwrap()))
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Rate limiting
// ──────────────────────────────────────────────────────────────────────────────

/// Resolve the client IP for rate limiting: the socket peer, unless the peer
/// is a trusted proxy in which case the X-Forwarded-For origin is used.
pub fn client_ip(state: &AppState, req: &Request) -> Option<IpAddr> {
    let peer = req
        .extensions()
        .get::<ConnectInfo<SocketAddr>>()
        .map(|ConnectInfo(addr)| addr.ip())?;

    let forwarded = req
        .headers()
        .get("x-forwarded-for")
        .and_then(|v| v.to_str().ok());

    resolve_client_ip(peer, forwarded, &state.config.server.api_trusted_proxies)
}

/// Pure decision logic behind [`client_ip`]: trust X-Forwarded-For only when
/// the socket peer is an explicitly configured proxy.
fn resolve_client_ip(
    peer: IpAddr,
    forwarded: Option<&str>,
    trusted_proxies: &[String],
) -> Option<IpAddr> {
    let peer_is_proxy = trusted_proxies.iter().any(|p| {
        p.trim()
            .parse::<IpAddr>()
            .map(|proxy| proxy == peer)
            .unwrap_or(false)
    });

    if peer_is_proxy {
        if let Some(origin) = forwarded
            .and_then(|chain| chain.split(',').next())
            .and_then(|ip| ip.trim().parse::<IpAddr>().ok())
        {
            return Some(origin);
        }
    }

    Some(peer)
}

/// Pre-auth limit keyed by client IP. Runs outermost so unauthenticated
/// traffic - including token guessing - is metered.
pub async fn ip_rate_limit_middleware(
    state: axum::extract::State<AppState>,
    req: Request,
    next: Next,
) -> Result<Response, ApiError> {
    if let Some(ip) = client_ip(&state, &req) {
        let key = format!("ip:{ip}");
        if state.ip_rate_limiter.check_key(&key).is_err() {
            return Err(ApiError::RateLimit(format!("rate limit exceeded for {ip}")));
        }
    }

    Ok(next.run(req).await)
}

/// Per-tenant limit for authenticated traffic. Requires the auth middleware
/// to have inserted an `AuthContext` extension first; requests that fail
/// authentication are stopped there and never reach this limiter.
pub async fn tenant_rate_limit_middleware(
    state: axum::extract::State<AppState>,
    req: Request,
    next: Next,
) -> Result<Response, ApiError> {
    let Some(auth) = req.extensions().get::<crate::auth::AuthContext>().cloned() else {
        tracing::error!("tenant rate limit ran without AuthContext - auth middleware missing");
        return Ok(next.run(req).await);
    };

    let key = auth.tenant_id.to_string();
    if state.rate_limiter.check_key(&key).is_err() {
        return Err(ApiError::RateLimit(format!(
            "rate limit exceeded for tenant {key}"
        )));
    }

    Ok(next.run(req).await)
}

#[cfg(test)]
mod tests {
    use super::resolve_client_ip;
    use std::net::IpAddr;

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    #[test]
    fn uses_peer_address_without_proxies() {
        assert_eq!(
            resolve_client_ip(ip("203.0.113.7"), Some("198.51.100.9"), &[]),
            Some(ip("203.0.113.7"))
        );
    }

    #[test]
    fn ignores_spoofed_forwarded_header_from_untrusted_peer() {
        // A direct client cannot mint an X-Forwarded-For origin.
        assert_eq!(
            resolve_client_ip(
                ip("203.0.113.7"),
                Some("1.2.3.4"),
                &["10.0.0.1".to_string()]
            ),
            Some(ip("203.0.113.7"))
        );
    }

    #[test]
    fn trusts_forwarded_origin_only_via_configured_proxy() {
        assert_eq!(
            resolve_client_ip(
                ip("10.0.0.1"),
                Some("198.51.100.9, 10.0.0.1"),
                &["10.0.0.1".to_string()]
            ),
            Some(ip("198.51.100.9"))
        );
    }

    #[test]
    fn falls_back_to_proxy_address_when_header_missing_or_invalid() {
        assert_eq!(
            resolve_client_ip(ip("10.0.0.1"), None, &["10.0.0.1".to_string()]),
            Some(ip("10.0.0.1"))
        );
        assert_eq!(
            resolve_client_ip(ip("10.0.0.1"), Some("not-an-ip"), &["10.0.0.1".to_string()]),
            Some(ip("10.0.0.1"))
        );
    }
}
