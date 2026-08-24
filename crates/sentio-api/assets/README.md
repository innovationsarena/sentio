# Vendored assets

## scalar-api-reference-1.66.1.js.gz

The Scalar API-reference UI: `dist/browser/standalone.js` from the
`@scalar/api-reference` 1.66.1 npm package, taken verbatim and gzipped. It is
embedded into the binary and served at `/docs/scalar-api-reference-1.66.1.js`
so the `/docs` page renders without outbound internet access.

- Source: <https://registry.npmjs.org/@scalar/api-reference/-/api-reference-1.66.1.tgz>
- SHA-256 of the uncompressed file, base64, as reported by the npm registry:
  `W1ByqL2bnC/7lGRh+eB1bdRN3a5d/a3B/xHee20UoPM=`
- Licence: MIT (Scalar, <https://github.com/scalar/scalar>). Not a cargo
  dependency, so cargo-about does not list it; this file is its attribution.

To upgrade: download the new package tarball, check the file hash against
`https://data.jsdelivr.com/v1/packages/npm/@scalar/api-reference@<version>`,
compress with `gzip -9n` (the `-n` keeps the output reproducible), and update
the version everywhere it appears in `src/routes/docs.rs`.
