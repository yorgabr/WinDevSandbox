# WinDevSandbox

WinDevSandbox is a reproducible PowerShell toolchain for Windows development in
corporate environments. It provides a structured and self-healing setup for
network connectivity, testing, and build orchestration.

![CI](https://github.com/yorgabr/WinDevSandbox)
https://img.shields.io/github/v/tag/yorgabr/WinDevSandbox

---

## What this project is

WinDevSandbox centralizes development infrastructure concerns that are typically
painful on Windows:

- Reliable network bootstrap (proxy-aware, CNTLM-friendly)
- Deterministic test execution with Pester 5
- Build orchestration via Invoke-Build
- Fully scriptable, non-interactive setup suitable for CI/CD

The goal is to make Windows development environments predictable, observable,
and easy to recover.

---

## Core components

- **BusterMyConnection**  
  Network bootstrap module that prefers proxy access when available and safely
  falls back to direct connectivity.

- **Invoke-Build orchestration**  
  A single, explicit build entrypoint that runs tests and validates the toolchain.

- **Pester test suite**  
  Tests are aligned with the actual behavioral contract of the system, ensuring
  reliable green builds without fragile internal coupling.

---

## Running locally

From the repository root:

```powershell
Invoke-Build
````

If the build completes successfully, your environment and dependencies are in a
known-good state.

***

## CI

All pushes and pull requests to `main` are validated using GitHub Actions on
Windows with the same Invoke-Build entrypoint used locally. A green badge means
the toolchain is healthy.

