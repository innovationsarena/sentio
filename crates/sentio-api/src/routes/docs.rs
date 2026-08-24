//! The API-reference page at `/docs`, self-contained.
//!
//! The stock utoipa-scalar page loads the Scalar front-end from a CDN, so on
//! a host without outbound internet access it renders blank. Here the bundle
//! is embedded in the binary instead and served from a route of our own, and
//! the page's `<script>` tag points at that route.

use std::io::Read;

use axum::http::header;
use axum::http::HeaderMap;
use axum::response::IntoResponse;

/// `@scalar/api-reference` 1.66.1, `dist/browser/standalone.js`, verbatim
/// from the npm package and gzipped. Provenance, hash, and licence:
/// `crates/sentio-api/assets/README.md`.
const SCALAR_JS_GZ: &[u8] = include_bytes!("../../assets/scalar-api-reference-1.66.1.js.gz");

/// The bundle version is part of the path, so an upgrade changes the URL and
/// the `immutable` cache directive below can never pin a browser to a stale
/// bundle.
pub const SCALAR_JS_PATH: &str = "/docs/scalar-api-reference-1.66.1.js";

/// The page served at `/docs`. Mirrors utoipa-scalar's default template, with
/// the CDN `<script>` swapped for [`SCALAR_JS_PATH`]; `$spec` is substituted
/// by `Scalar::to_html`.
pub const SCALAR_HTML: &str = r#"<!doctype html>
<html>
<head>
    <title>Sentio API</title>
    <meta charset="utf-8"/>
    <meta
            name="viewport"
            content="width=device-width, initial-scale=1"/>
</head>
<body>

<script
        id="api-reference"
        type="application/json">
    $spec
</script>
<script src="/docs/scalar-api-reference-1.66.1.js"></script>
</body>
</html>
"#;

// ──────────────────────────────────────────────────────────────────────────────
// GET /docs/scalar-api-reference-<version>.js - the embedded Scalar bundle
// ──────────────────────────────────────────────────────────────────────────────

/// Serves the bundle. The asset is stored gzipped (1.0 MiB against 3.6 MiB
/// raw), so a client that accepts gzip gets the bytes as they are and only a
/// client that does not pays for decompression.
pub async fn scalar_js(headers: HeaderMap) -> impl IntoResponse {
    let accepts_gzip = headers
        .get(header::ACCEPT_ENCODING)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| {
            value.split(',').any(|entry| {
                entry
                    .trim()
                    .split(';')
                    .next()
                    .is_some_and(|encoding| encoding.trim().eq_ignore_ascii_case("gzip"))
            })
        });

    let common = [
        (header::CONTENT_TYPE, "text/javascript; charset=utf-8"),
        (header::CACHE_CONTROL, "public, max-age=31536000, immutable"),
        (header::VARY, "Accept-Encoding"),
    ];

    if accepts_gzip {
        (common, [(header::CONTENT_ENCODING, "gzip")], SCALAR_JS_GZ).into_response()
    } else {
        // The asset is embedded at compile time, so a decode failure is a
        // build defect, not a runtime condition.
        let mut js = Vec::with_capacity(SCALAR_JS_GZ.len() * 4);
        flate2::read::GzDecoder::new(SCALAR_JS_GZ)
            .read_to_end(&mut js)
            .expect("embedded Scalar bundle is valid gzip");
        (common, js).into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_bundle_is_valid_gzip() {
        let mut js = Vec::new();
        flate2::read::GzDecoder::new(SCALAR_JS_GZ)
            .read_to_end(&mut js)
            .expect("decompress the embedded bundle");
        // The raw bundle is ~3.6 MiB; anything drastically smaller means the
        // asset was truncated or line-ending-normalised on the way in.
        assert!(js.len() > 3_000_000, "bundle is {} bytes", js.len());
    }

    #[test]
    fn page_references_the_embedded_bundle() {
        assert!(SCALAR_HTML.contains(SCALAR_JS_PATH));
        assert!(SCALAR_HTML.contains("$spec"));
    }
}
