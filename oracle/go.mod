module promoracle

go 1.25.0

// Prometheus's module version for release v3.13.2 is v0.313.2 — the repo tags
// releases as v3.x but the Go module path has no /vN suffix, so semantic import
// versioning pins it at v0. (`git describe` at the v3.13.2 tag reports v0.313.2.)
require github.com/prometheus/prometheus v0.313.2

require github.com/cespare/xxhash/v2 v2.3.0

require (
	github.com/dennwc/varint v1.0.0 // indirect
	github.com/grafana/regexp v0.0.0-20250905093917-f7b3be9d1853 // indirect
	github.com/prometheus/client_model v0.6.2 // indirect
	github.com/prometheus/common v0.69.0 // indirect
	golang.org/x/text v0.39.0 // indirect
	google.golang.org/protobuf v1.36.11 // indirect
)

// Pinned, read-only upstream worktree. See docs/PORTING.md.
replace github.com/prometheus/prometheus => ../../../prometheus/prometheus-v3.13.2
