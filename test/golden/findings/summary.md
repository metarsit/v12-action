## V12 security review

**V12 security review: 16 findings (4 critical, 4 high, 4 medium, 2 low, 2 info)** · gate **failing** (fail-on: high, 8 findings at or above) · [View run](https://v12.sh/runs/42)

| Severity | Count |
|---|---:|
| Critical | 4 |
| High | 4 |
| Medium | 4 |
| Low | 2 |
| Info | 2 |

**13 new, 2 resolved** since `9999999`.

| Severity | Finding | Location |
|---|---|---|
| Critical | [Signature replay across chains](https://v12.sh/runs/42/104) *(auto-invalidated)* | [`contracts/Permit.sol:30-41`](https://github.com/acme/vault/blob/1111111111111111111111111111111111111111/contracts/Permit.sol#L30-L41) |
| Critical | [Reentrancy in withdraw() lets a caller drain the vault](https://v12.sh/runs/42/101) | [`contracts/Vault.sol:118-121`](https://github.com/acme/vault/blob/1111111111111111111111111111111111111111/contracts/Vault.sol#L118-L121) |
| Critical | [Integer overflow in reward accounting](https://v12.sh/runs/42/103) *(auto-invalidated)* | [`contracts/Rewards.sol:55-57`](https://github.com/acme/vault/blob/1111111111111111111111111111111111111111/contracts/Rewards.sol#L55-L57) (outside the diff) |
| Critical | [Unchecked external call return value &#124; funds stuck in escrow](https://v12.sh/runs/42/102) **new** | [`contracts/Vault.sol:200`](https://github.com/acme/vault/blob/1111111111111111111111111111111111111111/contracts/Vault.sol#L200) |
| High | [&lt;script&gt;alert(1)&lt;/script&gt; Nonce reuse in signing routine](https://v12.sh/runs/42/118) **new** | [`src/crypto/sign.rs:90-105`](https://github.com/acme/vault/blob/1111111111111111111111111111111111111111/src/crypto/sign.rs#L90-L105) |
| High | [Missing access control on &#96;setOwner&#96;](https://v12.sh/runs/42/108) **new** | (no source location) (outside the diff) |
| High | [&lt;script&gt;alert(1)&lt;/script&gt; Nonce reuse in signing routine](https://v12.sh/runs/42/105) **new** | [`src/crypto/sign.rs:40-55`](https://github.com/acme/vault/blob/1111111111111111111111111111111111111111/src/crypto/sign.rs#L40-L55) |
| High | [Path traversal in module loader](https://v12.sh/runs/42/122) **new** | [`src/módulo/file name.sol:7-9`](https://github.com/acme/vault/blob/1111111111111111111111111111111111111111/src/m%C3%B3dulo/file%20name.sol#L7-L9) (outside the diff) |
| Medium | [Price manipulation through flash-loaned liquidity](https://v12.sh/runs/42/123) **new** | [`contracts/Vault.sol:250-262`](https://github.com/acme/vault/blob/1111111111111111111111111111111111111111/contracts/Vault.sol#L250-L262) |
| Medium | [Oracle staleness not checked](https://v12.sh/runs/42/119) **new** | [`contracts/Oracle.sol:44`](https://github.com/acme/vault/blob/1111111111111111111111111111111111111111/contracts/Oracle.sol#L44) (outside the diff) |
| Medium | [Überprüfung fehlt — signature malleability 🚨](https://v12.sh/runs/42/111) **new** | [`contracts/Permit.sol:70-72`](https://github.com/acme/vault/blob/1111111111111111111111111111111111111111/contracts/Permit.sol#L70-L72) |
| Medium | [Unbounded loop over depositors](https://v12.sh/runs/42/110) **new** *(auto-invalidated)* | [`contracts/Vault.sol:300-310`](https://github.com/acme/vault/blob/1111111111111111111111111111111111111111/contracts/Vault.sol#L300-L310) |
| Low | [Floating pragma](https://v12.sh/runs/42/113) **new** | [`contracts/Vault.sol:2`](https://github.com/acme/vault/blob/1111111111111111111111111111111111111111/contracts/Vault.sol#L2) |
| Low | [Rounding favours the caller in share math](https://v12.sh/runs/42/125) **new** | [`contracts/Vault.sol:140-142`](https://github.com/acme/vault/blob/1111111111111111111111111111111111111111/contracts/Vault.sol#L140-L142) |
| Info | [Event missing for ownership transfer](https://v12.sh/runs/42/114) **new** | [`contracts/Ownable.sol:20-22`](https://github.com/acme/vault/blob/1111111111111111111111111111111111111111/contracts/Ownable.sol#L20-L22) (outside the diff) |
| Info | [Redundant zero-address check](https://v12.sh/runs/42/124) **new** *(auto-invalidated)* | [`contracts/Vault.sol:80`](https://github.com/acme/vault/blob/1111111111111111111111111111111111111111/contracts/Vault.sol#L80) |

<details>
<summary>1 suppressed finding</summary>

| Severity | Finding | Reason | Expires |
|---|---|---|---|
| Medium | [Fenced snippet: markdown injection via &#96;&#96;&#96; in comments](https://v12.sh/runs/42/109) | Fence rendering only; tracked in SEC-77 | 2099-12-31 (@security-team) |
</details>

**Expired suppressions:** `c489c926ca7979b7` (expired 2020-01-01) — the findings are visible and gated again.

Hidden by filters: 4 by validity (kept: valid, unreviewed), 2 below min-severity (info), 2 in excluded paths.

### Target

| Target | Value |
|---|---|
| Repository | acme/vault |
| Mode | pr (diff) |
| Range | `2222222..1111111` |
| Pull request | #12 |
| V12 run | [42](https://v12.sh/runs/42) (completed) |

### Cost

| Cost | Value |
|---|---|
| Estimate | $12.50 (usage billing) |
| Realized | $12.50 |
| Files in scope | 3 |
| Billable changed lines | 37 |

### Gate settings

| Setting | Value |
|---|---|
| fail-on | high |
| include-validity | valid, unreviewed |
| ignore-auto-invalidated | false |
| min-severity | info |
| paths | (whole tree) |
| exclude-paths | &#42;&#42;/test/&#42;&#42; |

### Surfaces

| Surface | Result |
|---|---|
| Pull request comment | updated |
| Check run | created |
| SARIF | written, not uploaded (upload-sarif: false) |
| Slack | skipped (notify-on: gate-failure) |

---
duration 12m 30s · cost $12.50 (estimate $12.50, usage billing) · 3 files in scope · 3 changed files · range `2222222..1111111` · [full run](https://v12.sh/runs/42)
<sub>v12-action 1.0.0-test</sub>
