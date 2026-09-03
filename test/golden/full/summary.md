## V12 security review

**V12 security review: 16 findings (4 critical, 4 high, 5 medium, 3 low)** · gate **failing** (fail-on: critical, 4 findings at or above) · [View run](https://v12.sh/runs/42)

| Severity | Count |
|---|---:|
| Critical | 4 |
| High | 4 |
| Medium | 5 |
| Low | 3 |
| Info | 0 |

| Severity | Finding | Location |
|---|---|---|
| Critical | [Signature replay across chains](https://v12.sh/runs/42/104) *(auto-invalidated)* | [`contracts/Permit.sol:30-41`](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Permit.sol#L30-L41) |
| Critical | [Reentrancy in withdraw() lets a caller drain the vault](https://v12.sh/runs/42/101) | [`contracts/Vault.sol:118-121`](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Vault.sol#L118-L121) |
| Critical | [Integer overflow in reward accounting](https://v12.sh/runs/42/103) *(auto-invalidated)* | [`contracts/Rewards.sol:55-57`](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Rewards.sol#L55-L57) |
| Critical | [Unchecked external call return value &#124; funds stuck in escrow](https://v12.sh/runs/42/102) | [`contracts/Vault.sol:200`](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Vault.sol#L200) |
| High | [&lt;script&gt;alert(1)&lt;/script&gt; Nonce reuse in signing routine](https://v12.sh/runs/42/118) | [`src/crypto/sign.rs:90-105`](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/src/crypto/sign.rs#L90-L105) |
| High | [Missing access control on &#96;setOwner&#96;](https://v12.sh/runs/42/108) | (no source location) |
| High | [&lt;script&gt;alert(1)&lt;/script&gt; Nonce reuse in signing routine](https://v12.sh/runs/42/105) | [`src/crypto/sign.rs:40-55`](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/src/crypto/sign.rs#L40-L55) |
| High | [Path traversal in module loader](https://v12.sh/runs/42/122) | [`src/módulo/file name.sol:7-9`](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/src/m%C3%B3dulo/file%20name.sol#L7-L9) |
| Medium | [Price manipulation through flash-loaned liquidity](https://v12.sh/runs/42/123) | [`contracts/Vault.sol:250-262`](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Vault.sol#L250-L262) |
| Medium | [Fenced snippet: markdown injection via &#96;&#96;&#96; in comments](https://v12.sh/runs/42/109) | [`src/render.js:10-12`](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/src/render.js#L10-L12) |
| Medium | [Oracle staleness not checked](https://v12.sh/runs/42/119) | [`contracts/Oracle.sol:44`](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Oracle.sol#L44) |
| Medium | [Überprüfung fehlt — signature malleability 🚨](https://v12.sh/runs/42/111) | [`contracts/Permit.sol:70-72`](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Permit.sol#L70-L72) |
| Medium | [Unbounded loop over depositors](https://v12.sh/runs/42/110) *(auto-invalidated)* | [`contracts/Vault.sol:300-310`](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Vault.sol#L300-L310) |
| Low | [Mock contract returns hard-coded price](https://v12.sh/runs/42/112) | [`test/mocks/MockOracle.sol:5`](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/test/mocks/MockOracle.sol#L5) |
| Low | [Floating pragma](https://v12.sh/runs/42/113) | [`contracts/Vault.sol:2`](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Vault.sol#L2) |
| Low | [Rounding favours the caller in share math](https://v12.sh/runs/42/125) | [`contracts/Vault.sol:140-142`](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Vault.sol#L140-L142) |

Hidden by filters: 4 by validity (kept: valid, unreviewed), 5 below min-severity (low).

### Target

| Target | Value |
|---|---|
| Repository | acme/vault |
| Mode | full (full) |
| Commit | `3333333` on `main` |
| V12 run | [42](https://v12.sh/runs/42) (completed) |

### Cost

| Cost | Value |
|---|---|
| Estimate | $99.00 (fixed billing) |
| Realized | $12.50 |
| Files in scope | 3 |
| Billable changed lines | 0 |

### Gate settings

| Setting | Value |
|---|---|
| fail-on | critical |
| include-validity | valid, unreviewed |
| ignore-auto-invalidated | false |
| min-severity | low |
| paths | (whole tree) |
| exclude-paths | (none) |

### Surfaces

| Surface | Result |
|---|---|
| Pull request comment | updated |
| Check run | created |
| SARIF | written, not uploaded (upload-sarif: false) |
| Slack | skipped (notify-on: gate-failure) |

---
duration 12m 30s · cost $12.50 (estimate $99.00) · 3 files in scope · commit `3333333` on `main` · [full run](https://v12.sh/runs/42)
<sub>v12-action 1.0.0-test</sub>
