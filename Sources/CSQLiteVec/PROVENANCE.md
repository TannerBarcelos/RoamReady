# sqlite-vec provenance

- Project: sqlite-vec by Alex Garcia, https://github.com/asg017/sqlite-vec
- Version: v0.1.9 (source commit `e9f598abfa0c06b328d8fe5da9c3760cce74be10`, dated 2026-03-31)
- Obtained from: https://github.com/asg017/sqlite-vec/releases/download/v0.1.9/sqlite-vec-0.1.9-amalgamation.tar.gz
- Tarball SHA-256: `3acd67cb4aff080c7050926fd3cf8227905fe5b7ee3829d8ee5024ab1283cf61`
- Vendored unmodified (SHA-256):
  - `sqlite-vec.c` `ba081a47fa02eadc3cf6b16c314b695b84081269349aac722b4efa338fe8fd85`
  - `sqlite-vec.h` `8e4d7bfcd779c89bd19a6b2959fce24ee391b2eaf79a85a979377a36627cb060`
- License: dual MIT / Apache-2.0, used here under MIT. The texts are in `LICENSE-MIT` and `LICENSE-APACHE`,
  fetched from the v0.1.9 tag of the repository above.
  - `LICENSE-MIT` SHA-256 `6ce72bbe12d975bd5286e5ab0a064c069693300c47bccbc57bec18485f1621ea`
  - `LICENSE-APACHE` SHA-256 `a38070a94d4afd9cd710e3ce67bd1de78097cfe1784c1f0109ac95d3c196bfdc`

To upgrade, replace both source files from a newer release tarball, update this note, and rerun `swift test`.
Do not edit the vendored files; the build wrapper is `csqlitevec.c`.
The wrapper includes `sqlite-vec.c`, which is excluded from standalone compilation in `Package.swift`.
Clang's `-Wshorten-64-to-32` diagnostic is suppressed only around that include to accommodate
upstream's integer conversions under Xcode's stricter warning settings. Other diagnostics and
conversion warnings in the wrapper remain enabled. This does not change upstream's conversion behavior.
