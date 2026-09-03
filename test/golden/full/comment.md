<!-- v12-audit-action:full -->

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

<details>
<summary>Critical: Signature replay across chains</summary>

**Description**

The permit digest omits the chain id. A reviewer confirmed this despite the automatic invalidation.

**Impact**

Signatures can be replayed on forks.

**Root cause**

EIP-712 domain separator without chainId.

```solidity
bytes32 digest = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
```

Fingerprint `c9ecb9cf8cf93ea3` · validity valid · [View on V12](https://v12.sh/runs/42/104) · [Source](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Permit.sol#L30-L41)
</details>
<details>
<summary>Critical: Reentrancy in withdraw() lets a caller drain the vault</summary>

**Description**

&#96;withdraw()&#96; sends ETH with &#96;call&#96; before updating &#96;balances&#91;msg.sender&#93;&#96;, so a malicious receiver can re-enter and withdraw repeatedly.

**Impact**

Complete loss of vault funds.

**Root cause**

State update happens after the external call (checks-effects-interactions violated).

*external call before state update*

```solidity
(bool ok, ) = msg.sender.call{value: amount}("");
require(ok, "transfer failed");
balances[msg.sender] -= amount;
```

Fingerprint `03fd1caea09bb909` · validity valid · [View on V12](https://v12.sh/runs/42/101) · [Source](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Vault.sol#L118-L121)
</details>
<details>
<summary>Critical: Integer overflow in reward accounting</summary>

**Description**

Auto-invalidated by V12&#39;s PoC run: Solidity 0.8 checked arithmetic prevents this.

**Impact**

None (auto-invalidated).

**Root cause**

Analysis assumed unchecked arithmetic.

```solidity
total += amount;
```

Fingerprint `d8c8bf0ce16a1089` · validity unreviewed · [View on V12](https://v12.sh/runs/42/103) · [Source](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Rewards.sol#L55-L57)
</details>
<details>
<summary>Critical: Unchecked external call return value &#124; funds stuck in escrow</summary>

**Description**

The return value of &#96;token.transfer&#96; is ignored.

**Impact**

Tokens can be silently lost.

**Root cause**

Missing require on the boolean return value.

```solidity
token.transfer(to, amount);
```

Fingerprint `75001bd88146f0dc` · validity unreviewed · [View on V12](https://v12.sh/runs/42/102) · [Source](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Vault.sol#L200)
</details>
<details>
<summary>High: &lt;script&gt;alert(1)&lt;/script&gt; Nonce reuse in signing routine</summary>

**Description**

Second instance of the same nonce derivation (duplicate fingerprint case).

**Impact**

Key recovery.

**Root cause**

Same as above.

```rust
let k = now_secs() as u64;
let sig = sign_with_nonce(&key, &msg, k);
```

Fingerprint `76e409073bcd488c` · validity valid · [View on V12](https://v12.sh/runs/42/118) · [Source](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/src/crypto/sign.rs#L90-L105)
</details>
<details>
<summary>High: Missing access control on &#96;setOwner&#96;</summary>

**Description**

No location could be attributed: the function is generated by a proxy pattern at deploy time.

**Impact**

Anyone can take ownership.

**Root cause**

Generated setter lacks the onlyOwner modifier.

Fingerprint `ca54c1231dd564f3` · validity unreviewed · [View on V12](https://v12.sh/runs/42/108)
</details>
<details>
<summary>High: &lt;script&gt;alert(1)&lt;/script&gt; Nonce reuse in signing routine</summary>

**Description**

The nonce is derived from the timestamp with second resolution.

**Impact**

Private key recovery from two signatures in the same second.

**Root cause**

Deterministic nonce without message binding.

*nonce derivation*

```rust
let k = now_secs() as u64;
let sig = sign_with_nonce(&key, &msg, k);
```

Fingerprint `76e409073bcd488c` · validity unreviewed · [View on V12](https://v12.sh/runs/42/105) · [Source](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/src/crypto/sign.rs#L40-L55)
</details>
<details>
<summary>High: Path traversal in module loader</summary>

**Description**

User-controlled module names are joined to a base path without normalisation.

**Impact**

Arbitrary file read.

**Root cause**

Missing path normalisation.

```solidity
string memory p = string(abi.encodePacked(base, "/", name));
```

Fingerprint `726c9cf20e4e84bd` · validity unreviewed · [View on V12](https://v12.sh/runs/42/122) · [Source](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/src/m%C3%B3dulo/file%20name.sol#L7-L9)
</details>
<details>
<summary>Medium: Price manipulation through flash-loaned liquidity</summary>

**Description**

&#35; Not a heading

The spot price is read from the pool reserves in the same transaction.

- reserves can be moved with a flash loan
- the vault mints against the manipulated price

See &lt;https://example.com/flash&gt; and the &#96;getPrice()&#96; helper. Ends with an HTML comment terminator: --&gt;

**Impact**

Under-collateralised minting. &#42;&#42;Bold&#42;&#42; should render literally.

**Root cause**

Spot price used as oracle.

*spot price read*

```solidity
(uint112 r0, uint112 r1, ) = pair.getReserves();
uint256 price = r1 * 1e18 / r0;
```

Fingerprint `44d3f84c9ccf8d87` · validity valid · [View on V12](https://v12.sh/runs/42/123) · [Source](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Vault.sol#L250-L262)
</details>
<details>
<summary>Medium: Fenced snippet: markdown injection via &#96;&#96;&#96; in comments</summary>

**Description**

A snippet that contains a triple fence:

&#96;&#96;&#96;
not code
&#96;&#96;&#96;

and a stray --&gt; arrow.

**Impact**

Rendering breakage.

**Root cause**

Unescaped fences.

````javascript
const s = '```';
const t = `` + s;
// -->
````

Fingerprint `28c66ae399b0de16` · validity valid · [View on V12](https://v12.sh/runs/42/109) · [Source](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/src/render.js#L10-L12)
</details>
<details>
<summary>Medium: Oracle staleness not checked</summary>

**Description**

latestRoundData() is used without checking updatedAt.

**Impact**

Stale prices accepted.

**Root cause**

Missing freshness check.

*only startLine reported*

Fingerprint `6bf6cb80de410fab` · validity unreviewed · [View on V12](https://v12.sh/runs/42/119) · [Source](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Oracle.sol#L44)
</details>
<details>
<summary>Medium: Überprüfung fehlt — signature malleability 🚨</summary>

**Description**

ecrecover accepts high-s signatures.

**Impact**

Replay with a malleated signature.

**Root cause**

No s-value bound check.

```solidity
address signer = ecrecover(digest, v, r, s);
```

Fingerprint `f13a7794ac00ef21` · validity unreviewed · [View on V12](https://v12.sh/runs/42/111) · [Source](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Permit.sol#L70-L72)
</details>
<details>
<summary>Medium: Unbounded loop over depositors</summary>

**Description**

Auto-invalidated: the array is capped at 100 entries elsewhere.

**Impact**

Gas exhaustion.

**Root cause**

Unbounded iteration.

```solidity
for (uint i = 0; i < depositors.length; i++) {
```

Fingerprint `e0c83f9665503f0a` · validity unreviewed · [View on V12](https://v12.sh/runs/42/110) · [Source](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Vault.sol#L300-L310)
</details>
<details>
<summary>Low: Mock contract returns hard-coded price</summary>

**Description**

Test mock only.

**Impact**

None in production.

**Root cause**

Test fixture.

```solidity
return 1e18;
```

Fingerprint `3fa548a8706d52b8` · validity valid · [View on V12](https://v12.sh/runs/42/112) · [Source](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/test/mocks/MockOracle.sol#L5)
</details>
<details>
<summary>Low: Floating pragma</summary>

**Description**

pragma solidity ^0.8.0 allows compilation with future compilers.

**Impact**

Unexpected compiler behaviour.

**Root cause**

Unpinned pragma.

```solidity
pragma solidity ^0.8.0;
```

Fingerprint `c489c926ca7979b7` · validity unreviewed · [View on V12](https://v12.sh/runs/42/113) · [Source](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Vault.sol#L2)
</details>
<details>
<summary>Low: Rounding favours the caller in share math</summary>

**Description**

Both deposit and redeem round in the caller&#39;s favour.

**Impact**

Slow value leak.

**Root cause**

Rounding direction.

*deposit*

```solidity
shares = amount * totalShares / totalAssets;
```

2 source locations; the first is shown.

Fingerprint `c40df8f19d04fda8` · validity unreviewed · [View on V12](https://v12.sh/runs/42/125) · [Source](https://github.com/acme/vault/blob/3333333333333333333333333333333333333333/contracts/Vault.sol#L140-L142)
</details>

Hidden by filters: 4 by validity (kept: valid, unreviewed), 5 below min-severity (low).

---
duration 12m 30s · cost $12.50 (estimate $99.00) · 3 files in scope · commit `3333333` on `main` · [full run](https://v12.sh/runs/42)
<sub>v12-action 1.0.0-test</sub>

<!-- v12-audit-action:state:eyJ2IjoxLCJzaGEiOiIzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzIiwicnVuIjo0MiwiZnBzIjpbImM5ZWNiOWNmOGNmOTNlYTMiLCIwM2ZkMWNhZWEwOWJiOTA5IiwiZDhjOGJmMGNlMTZhMTA4OSIsIjc1MDAxYmQ4ODE0NmYwZGMiLCI3NmU0MDkwNzNiY2Q0ODhjIiwiY2E1NGMxMjMxZGQ1NjRmMyIsIjc2ZTQwOTA3M2JjZDQ4OGMiLCI3MjZjOWNmMjBlNGU4NGJkIiwiNDRkM2Y4NGM5Y2NmOGQ4NyIsIjI4YzY2YWUzOTliMGRlMTYiLCI2YmY2Y2I4MGRlNDEwZmFiIiwiZjEzYTc3OTRhYzAwZWYyMSIsImUwYzgzZjk2NjU1MDNmMGEiLCIzZmE1NDhhODcwNmQ1MmI4IiwiYzQ4OWM5MjZjYTc5NzliNyIsImM0MGRmOGYxOWQwNGZkYTgiXSwic2xhY2tUcyI6IjE3MDAwMDAwMDAuMDAwMTAwIiwic2xhY2tDaGFubmVsIjoiQzAxMjMifQ== -->