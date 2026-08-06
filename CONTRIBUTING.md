# Contributing

Contributions are welcome. Please read `PROJECT.md` (the implementation
brief) and `ARCHITECTURE.md` first — they define the scope, the
milestone plan, and the coding rules.

Ground rules:

* Every milestone must leave the repository compiling, documented and
  tested (`nimble test` green).
* No new external non-Nim dependencies. External pure-Nim dependencies
  need a strong reason.
* Follow the coding rules in `PROJECT.md` section 26 (no `readAll`, no
  unbounded queues, no exceptions across thread boundaries, checked
  arithmetic for external lengths, comments on every cast/raw pointer,
  regression test before every decoder bug fix, …).
* Keep the vendored sources' modifications documented in
  `src/vendor/README.md`.
* Update `ARCHITECTURE.md` whenever ownership or scheduling behaviour
  changes.

Useful commands: `nimble test`, `nimble testFast`, `nimble testSanitize`,
`nimble fuzzSmoke`, `nimble testPackage`, `nimble docs`.
