#!/usr/bin/env bash
# lib/pins.sh — exact versions and SHA-256 digests of everything rig
# downloads. Nothing is fetched by "latest" or from a moving branch.
#
# To bump: download each asset from its release page, check it against the
# upstream checksums where published, and update version and digests
# together in one PR. Changes here are merged by the owner (REVIEW.md).

# shellcheck disable=SC2034  # read by lib/beads.sh and bin/rig-ci-tools

# beads (bd) — https://github.com/gastownhall/beads/releases
# Digests match the release's checksums.txt.
RIG_BD_VERSION="1.3.1"
RIG_BD_SHA256_linux_amd64="3219443a9734b89b93fb16ee8d65844759fa1b3cd3cf139c606b7353cfb0715c"
RIG_BD_SHA256_linux_arm64="c3b32c71a6c0cd6358a12c28272b17e6818db991da192f87df52339c222e423a"

# dolt — https://github.com/dolthub/dolt/releases
# No upstream checksum file; digests recorded at pin time.
RIG_DOLT_VERSION="2.4.2"
RIG_DOLT_SHA256_linux_amd64="5d95a271149dc6ea97f47157af7ba9a0df5e8d4e9bbac4d79c169f2faa3cfb9e"
RIG_DOLT_SHA256_linux_arm64="c1c610e22c6bacd4c5b2fbf5697a0f453d759d075c4abff380c6e646553e22d8"

# CI only (bin/rig-ci-tools): the linters bin/rig-check runs, pinned so a
# runner image update cannot change what passes.

# ShellCheck: https://github.com/koalaman/shellcheck/releases
# No upstream checksum file; digests recorded at pin time.
RIG_SHELLCHECK_VERSION="0.11.0"
RIG_SHELLCHECK_SHA256_linux_amd64="8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"
RIG_SHELLCHECK_SHA256_linux_arm64="12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588"

# actionlint: https://github.com/rhysd/actionlint/releases
# Digests match the release's checksums file.
RIG_ACTIONLINT_VERSION="1.7.7"
RIG_ACTIONLINT_SHA256_linux_amd64="023070a287cd8cccd71515fedc843f1985bf96c436b7effaecce67290e7e0757"
RIG_ACTIONLINT_SHA256_linux_arm64="401942f9c24ed71e4fe71b76c7d638f66d8633575c4016efd2977ce7c28317d0"
