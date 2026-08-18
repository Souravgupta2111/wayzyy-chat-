# Wayzyy moderation service.
#
# Two properties this file is built around.
#
# **The invariant gate runs during the build.** The image cannot be produced if a safety
# guarantee is violated — self-harm becoming blockable, harassment becoming hard-blockable, a
# degraded path acquiring the ability to enforce. A gate that only runs in CI can be bypassed by
# building locally and pushing; a gate in the build cannot.
#
# **The runtime image contains a binary and nothing else.** No compiler, no package manager, no
# shell utilities, no source. A moderation service handles the most sensitive text on the
# platform, so the blast radius of a compromise should be one static binary and a socket.

# ─────────────────────────────── build ───────────────────────────────
FROM swift:5.9-jammy AS build

WORKDIR /build

# Only what the service actually needs. The SwiftUI app targets are deliberately excluded: they
# are not part of the service, and copying them would put view code and chat fixtures into an
# image that has no use for either.
COPY Package.swift ./
COPY WayzyyChat/Moderation ./WayzyyChat/Moderation
COPY Sources ./Sources
# Model weights and the abuse lexicon. Copied in the build stage as well so the invariant gate
# below runs against the same data the runtime will use — a gate that passes without the model
# is not testing the configuration being shipped.
COPY config ./config

# Static stdlib so the runtime stage needs no Swift toolchain.
RUN swift build -c release --static-swift-stdlib

# The gate. Exits non-zero on any violated invariant, which fails the build.
RUN .build/release/wayzyy-invariants

# ────────────────────────────── runtime ──────────────────────────────
FROM ubuntu:22.04

# ca-certificates so the Tier 3 adjudicator's TLS can be verified — without it every HTTPS
# adjudication fails, and the service would fall back to holding messages it could have judged.
# libcurl and libxml2 are Foundation's runtime dependencies even with a static stdlib.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libcurl4 \
        libxml2 \
        libssl3 \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# Unprivileged, with a fixed uid so a mounted volume's ownership is predictable.
RUN groupadd --gid 10001 wayzyy \
    && useradd --uid 10001 --gid 10001 --create-home --shell /usr/sbin/nologin wayzyy

COPY --from=build /build/.build/release/wayzyy-moderate-http /usr/local/bin/
COPY --from=build /build/.build/release/wayzyy-moderate      /usr/local/bin/
COPY --from=build /build/.build/release/wayzyy-invariants    /usr/local/bin/

# The learned abuse router and the abuse lexicon are data, not code, and both are loaded from
# disk at startup. Without them the service still runs — it degrades to structural signals only
# and says so in its startup report — which is the failure mode most likely to go unnoticed,
# because nothing errors. They are given an explicit home and pointed at by environment so the
# search never depends on the working directory.
COPY config /etc/wayzyy/
ENV WAYZYY_ABUSE_ROUTER=/etc/wayzyy/abuse-router.weights \
    WAYZYY_SLUR_LEXICON=/etc/wayzyy/slurs.json

# Where the decision log lands when WAYZYY_DECISION_LOG points here. Owned by the runtime user
# so the service can write it without running privileged.
RUN mkdir -p /var/lib/wayzyy && chown 10001:10001 /var/lib/wayzyy
VOLUME ["/var/lib/wayzyy"]

USER 10001:10001
EXPOSE 8080

# Probes are HTTP and intentionally unauthenticated: a probe that needs a credential fails
# during exactly the incident it exists to report.
#   GET /health  liveness  — is the process up
#   GET /ready   readiness — is it configured well enough to receive traffic
#
# No HEALTHCHECK instruction and no HTTP client in the image: adding curl to satisfy Docker's
# healthcheck would widen the runtime surface for something the orchestrator already does.

ENV WAYZYY_PORT=8080 \
    WAYZYY_DECISION_LOG=/var/lib/wayzyy/decisions.jsonl \
    WAYZYY_REQUIRE_TIER3=1
# File log is the single-node fallback. SUPABASE_URL still wins when set.

ENTRYPOINT ["wayzyy-moderate-http"]
