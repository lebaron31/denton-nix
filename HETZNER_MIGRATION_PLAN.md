# HETZNER_MIGRATION_PLAN.md — global source migration → denton-obj

> **Goal:** get *everything meaningful* onto Hetzner object storage (`denton-obj:`), in a clean,
> deduped, **checksum-verified** layout, so we can truthfully report **"everything is on Hetzner."**
> **Guardrail (privacy-absolute):** finance / vice / PII / secrets **NEVER egress unencrypted.**
> They are EXCLUDED, or pushed only through an **age/gpg-encrypted vault** (`denton-vault/`).
> **Plan only — nothing here is run.** Companion to `ops/hermes/cloud_rebase.sh` (extends it).

Engine: `rclone sync --checksum` (idempotent, resumable, only-changed). Verify: `rclone check
--checksum --one-way`. Dedup: `rclone dedupe newest --by-hash`. Style/contract matches
`SECRETS.md §5` + `denton-cloud.nix` (out-of-band `RCLONE_CONFIG`, no secrets in nix store).

---

## 0. State of the world (recon 2026-06-22, this box = brainstem)

**Two syncs are LIVE right now** (PID 1273692 + 1289660) — the plan **must sequence around them**:
- `rclone sync ~/Dropbox → denton-obj:cloud-sources/dropbox/` (22G, in flight)
- `rclone sync gdrive: → denton-obj:cloud-sources/gdrive/primary/` (account 1 of 7, in flight)

**rclone remotes (8):** `denton-obj:` (Hetzner dest) + **7 gdrive accounts** —
`gdrive` (→`primary`), `gdrive-kim-hurt-r`, `gdrive-krimsonfixx`, `gdrive-lebaron31`,
`gdrive-ncrypted`, `gdrive-nfuzionmusic`, `gdrive-poisonlilac`. The `cloud_rebase.sh gdrive` case
already maps each `gdrive*` remote → `cloud-sources/gdrive/<label>/` (label = `${rem#gdrive-}`,
bare `gdrive`→`primary`). **No change needed there** — but it runs them serially in one process; we
add explicit sequencing + the **EXCLUDE list** for `gdrive-ncrypted` (see §2).

**Local source sizes (`du -sh`, verified):**

| Source | Size | Notes |
|---|---|---|
| `~/denton-projects` | 183G | the system; mostly project repos + `_consolidated` |
| `~/.cache/huggingface` | 31G | HF model cache (machine-archive) |
| `~/Dropbox` | 22G | live, local (no OAuth) — sync in flight |
| `~/Downloads` | 1.4G | machine archive (triage) |
| `~/.config` | 826M | machine config (secret-bearing — EXCLUDE/encrypt) |
| `~/Desktop` | 39M | machine archive (triage) |
| `~/.ollama` | 28K | empty (Ollama banned) — SKIP |

**`~/denton-projects` is 183G but 101G of it is `_consolidated/` — and 85G of THAT is one dir:**
`_consolidated/staging/backups/Dropbox (Old)/` — a stale copy of Dropbox. **Dedup target, not a
second upload.** Remaining staging: `mnt_archives` 6.4G, `synapse_archive` 3.8G, `synapse` 2.1G,
`data` 1.3G, `models` 941M, `by_project` 967M, `old_projects` 446M.

**git repos under `~/denton-projects` (14 top-level .git + 5 submodules):**
`comms dentoncode denton-qx finance home kari-projects kim-projects mike-projects music nix qx
spyder-game voice wavez_music_ecosystem`; submodules: `denton-inference/hipfire`,
`denton-vendor/llama.cpp`, `people/{kim,mike,kari}-projects`. `dentoncode/.git` alone = 1.4G.

---

## 1. denton-obj: target structure (extends cloud_rebase.sh)

```
denton-obj:
├── cloud-sources/                  # external clouds (cloud_rebase.sh owns these)
│   ├── dropbox/                    #  ← ~/Dropbox (22G)            [IN FLIGHT]
│   ├── gdrive/
│   │   ├── primary/                #  ← gdrive:                    [IN FLIGHT]
│   │   ├── kim-hurt-r/  krimsonfixx/  lebaron31/  nfuzionmusic/  poisonlilac/
│   │   └── ncrypted/   →  *** EXCLUDED from plaintext — see §2 (encrypt-only) ***
│   └── lyrics/{matched,unsorted}/  # post-ingest lyrics_sort.py (cloud_rebase.sh lyrics)
│
├── machine-archive/                # this box, non-repo
│   ├── hf-models/                  #  ← ~/.cache/huggingface (31G) (cloud_rebase.sh hf)
│   ├── consolidated/               #  ← ~/denton-projects/_consolidated/staging (DEDUPED, see §3)
│   │   ├── mnt-archives/ synapse-archive/ synapse/ data/ models/ by_project/ old_projects/ misc/
│   │   └── (NO  backups/Dropbox (Old)/  — that is dedup-dropped against cloud-sources/dropbox/)
│   ├── home-archive/               #  ← ~/Downloads ~/Desktop (triaged; NO ~/.config — §2)
│   └── ollama/                     #  (empty today — placeholder)
│
├── system-repos/                   # the canonical git repos (code + history)
│   ├── dentoncode/  denton-qx/  music/  spyder-game/  wavez/  nix/  qx/  home/  comms/  voice/
│   └── (bundles, not working trees — see §4)
│
├── people/                         # family repos — PII-ADJACENT (see §2 classification)
│   └── { kim-projects, mike-projects, kari-projects }   # → ENCRYPT (kept out of plaintext)
│
└── denton-vault/                   # *** ENCRYPTED-ONLY *** (age/gpg) — the privacy firewall
    ├── finance.age                 #  ← finance/        (binance/coinbase/apple-card/budget — PII)
    ├── personal.age                #  ← denton-personal/  + staging/private/denton-private
    ├── env-bundle.age              #  ← every .env / secrets/ / config with keys (§2 list)
    └── people-*.age                #  ← kim/mike/kari repos (if any real PII inside)
```

Rationale: `cloud-sources/` (external clouds) and `machine-archive/hf-models/` already exist in
`cloud_rebase.sh` — we **keep those paths verbatim** and only ADD `machine-archive/consolidated`,
`system-repos/`, `people/`, and the encrypted `denton-vault/`.

---

## 2. Classification — MIGRATE / SKIP / EXCLUDE-or-ENCRYPT

**Decision rule:** code+history → `system-repos/`. Bulk data/models/archives → `machine-archive/`.
External clouds → `cloud-sources/`. **Anything with money, identity, vice, or a live key → never
plaintext** (EXCLUDE, or `denton-vault/*.age`).

### MIGRATE (plaintext OK)
| Source | Dest | Phase |
|---|---|---|
| `~/Dropbox` | `cloud-sources/dropbox/` | running (§5 P0) |
| `gdrive:` + 5 labeled (`kim-hurt-r krimsonfixx lebaron31 nfuzionmusic poisonlilac`) | `cloud-sources/gdrive/<label>/` | §5 P1 |
| `~/.cache/huggingface` | `machine-archive/hf-models/` | §5 P3 |
| `_consolidated/staging/{mnt_archives,synapse_archive,synapse,data,models,by_project,old_projects,misc,archives}` | `machine-archive/consolidated/...` | §5 P3 (after dedup §3) |
| `~/Downloads`, `~/Desktop` | `machine-archive/home-archive/` | §5 P4 (triage first) |
| repos: `dentoncode denton-qx music spyder-game wavez_music_ecosystem nix qx home comms voice` | `system-repos/<repo>/` as git bundles | §5 P2 (§4) |

### JUNK / SKIP (do not upload)
- `~/.ollama` (28K, empty — Ollama banned).
- `**/.git` working-internals when we instead push a `git bundle` (§4) — avoids the 1.4G
  `dentoncode/.git` blob churn on every sync; the bundle carries full history in one verifiable file.
- `**/node_modules`, `**/target`, `**/__pycache__`, `**/.venv`, `**/*.pyc`, build/`result` symlinks,
  `.claude/worktrees/` — regenerable, never source of truth. (rclone `--exclude` filters, §5.)
- `_consolidated/staging/backups/Dropbox (Old)/` (85G) — **stale dup of live Dropbox →
  dedup-dropped** (§3), not uploaded.
- `_consolidated/{20260616_*,dropbox_stage}` — tiny stale consolidation receipts.

### EXCLUDE-or-ENCRYPT (privacy-absolute — NO plaintext egress)
| Sensitive source | Why | Handling |
|---|---|---|
| `finance/` (3860 files: `binance_connector.py` `coinbase_connector.py` `apple_card_setup.md` `budget_engine.py` `bill_tracker.py` `data/`) | money + account PII | `denton-vault/finance.age` only |
| `denton-personal/drive/` | personal/PII | `denton-vault/personal.age` only |
| `_consolidated/staging/private/denton-private` | flagged private | `denton-vault/personal.age` |
| `_consolidated/staging/configs/{denton_mobile_env,denton_proxy.json,config.json,entity_registry.json,soul_template.toml}` | may hold tokens/endpoints | review → encrypt or drop |
| **All `.env` + secrets** found: `denton-projects/.env`, `full/.env`, `runpod/.env`, `commands/.env`, `dentoncode/.env`, `sandbox-dryrun/.env`, `directives/.env`, `dentoncode/nix/secrets`, plus any `*.key` / `rclone.conf` | **live API keys** | `denton-vault/env-bundle.age`; **GLOBAL rclone `--exclude` so they can NEVER ride along** in any other sync |
| `gdrive-ncrypted:` | the *name* says encrypted/sensitive | EXCLUDE from `cloud-sources/gdrive/` plaintext; if mirrored, `denton-vault/` only — **confirm with Chase first** |
| `~/.config` (826M) | app creds, tokens, browser/keyring | EXCLUDE (machine creds, not a deliverable); cherry-pick to vault only if a config is truly needed |
| `people/{kim,mike,kari}-projects` | family data, possible PII | default **ENCRYPT** (`denton-vault/people-*.age`) unless a per-repo scan proves it's pure code |

**Hard global filter (applies to EVERY rclone push in §5):**
```
--exclude '.env' --exclude '**/.env' --exclude '**/secrets/**' --exclude '*.key' \
--exclude '**/rclone.conf' --exclude '**/id_*' --exclude '**/*.pem' \
--exclude '**/node_modules/**' --exclude '**/target/**' --exclude '**/__pycache__/**' \
--exclude '**/.venv/**' --exclude '**/result' --exclude '**/.git/**'
```
> The `--exclude '.env'` family is the **privacy fuse**: even a mis-scoped sync cannot leak a key.

---

## 3. Dedup BEFORE upload (kills the 85G redundant push)

The single biggest win: `_consolidated/staging/backups/Dropbox (Old)/` (85G) is a stale copy of
`~/Dropbox` (22G live). **Do not upload it.** Two safe options (plan-only):

- **Preferred (no extra egress):** never push `backups/Dropbox (Old)/`; after the live Dropbox sync
  (§5 P0) lands in `cloud-sources/dropbox/`, run remote-side dedup so any incidental overlap
  collapses:
  ```bash
  rclone dedupe newest --by-hash denton-obj:cloud-sources/    # already in cloud_rebase.sh `dedup`
  rclone dedupe newest --by-hash denton-obj:machine-archive/  # extend to machine-archive too
  ```
- **Verify-then-drop:** confirm the old copy is a strict subset of live Dropbox before excluding:
  ```bash
  rclone check "$HOME/denton-projects/_consolidated/staging/backups/Dropbox (Old)" \
    "$HOME/Dropbox" --checksum --one-way   # one-way: every old file exists+matches in live
  ```
  If clean → exclude the dir from the consolidated push (saves ~85G of upload + storage).

---

## 4. Repos as git bundles (full history, one verifiable file)

Syncing working trees double-counts `.git` (1.4G for dentoncode) and races the index. Instead push
**bundles** — one file per repo, complete history, hash-checkable:
```bash
# per repo (plan; run from each repo root):
git bundle create /tmp/<repo>.bundle --all
rclone copyto /tmp/<repo>.bundle denton-obj:system-repos/<repo>/<repo>-$(date +%Y%m%d).bundle --checksum
# restore later:  git clone <repo>.bundle <repo>
```
Apply to: `dentoncode denton-qx music spyder-game wavez_music_ecosystem nix qx home comms voice`
(skip `finance` → vault; people-repos → vault unless scan-clean). Submodules ride in `--all` of the
parent where vendored; `llama.cpp`/`hipfire` are upstream — record the submodule URL+SHA, don't
re-upload upstream history.

---

## 5. Sequenced rclone commands (avoid bandwidth contention)

**Constraint:** Dropbox + gdrive-primary are saturating upstream NOW. Run phases **serially**; cap
concurrency so a new push can't starve the in-flight ones. Global flags for every push:
`--checksum --transfers 4 --tpslimit 10 --stats 30s --stats-one-line` (+ the §2 hard filter).
Add `--bwlimit 50M` only if Chase reports the link is choking; default is to let P0/P1 finish first.

```bash
HZ="denton-obj:"
GUARD="--exclude .env --exclude **/.env --exclude **/secrets/** --exclude *.key \
  --exclude **/rclone.conf --exclude **/id_* --exclude **/*.pem \
  --exclude **/node_modules/** --exclude **/target/** --exclude **/__pycache__/** \
  --exclude **/.venv/** --exclude **/result --exclude **/.git/**"
COMMON="--checksum --transfers 4 --tpslimit 10 --stats 30s --stats-one-line"
```

**P0 — let the in-flight syncs finish (DO NOT start new pushes yet).** Gate on:
```bash
until ! pgrep -f 'rclone sync .*Dropbox' >/dev/null && \
      ! pgrep -f 'rclone sync gdrive:' >/dev/null; do sleep 60; done   # poll, don't pile on
```

**P1 — remaining 5 gdrive accounts (serial; ncrypted EXCLUDED):**
```bash
for rem in gdrive-kim-hurt-r gdrive-krimsonfixx gdrive-lebaron31 gdrive-nfuzionmusic gdrive-poisonlilac; do
  label="${rem#gdrive-}"
  rclone sync "${rem}:" "${HZ}cloud-sources/gdrive/${label}/" $COMMON $GUARD
  rclone check "${rem}:" "${HZ}cloud-sources/gdrive/${label}/" --checksum --one-way 2>&1 | tail -3
done
# gdrive-ncrypted: → HELD. Encrypt-only or confirm-with-Chase (see §2). NOT pushed here.
```

**P2 — system repos as bundles (cheap, fast, do while gdrive trickles):**
```bash
for r in dentoncode denton-qx music spyder-game wavez_music_ecosystem nix qx home comms voice; do
  ( cd "$HOME/denton-projects/$r" && git bundle create "/tmp/$r.bundle" --all ) && \
  rclone copyto "/tmp/$r.bundle" "${HZ}system-repos/$r/$r-$(date +%Y%m%d).bundle" --checksum && \
  rm -f "/tmp/$r.bundle"
done
```

**P3 — HF cache + consolidated archive (the big bulk; run AFTER clouds, lowest priority):**
```bash
rclone sync "$HOME/.cache/huggingface" "${HZ}machine-archive/hf-models/" $COMMON
rclone check "$HOME/.cache/huggingface" "${HZ}machine-archive/hf-models/" --checksum --one-way | tail -3

CONS="$HOME/denton-projects/_consolidated/staging"
for d in mnt_archives synapse_archive synapse data models by_project old_projects misc archives; do
  rclone sync "$CONS/$d" "${HZ}machine-archive/consolidated/$d/" $COMMON $GUARD
  rclone check "$CONS/$d" "${HZ}machine-archive/consolidated/$d/" --checksum --one-way | tail -3
done
# NOTE: backups/Dropbox (Old)/  is deliberately NOT in the loop (dedup-dropped, §3).
```

**P4 — home archive triage (smallest, last):**
```bash
rclone sync "$HOME/Downloads" "${HZ}machine-archive/home-archive/Downloads/" $COMMON $GUARD
rclone sync "$HOME/Desktop"   "${HZ}machine-archive/home-archive/Desktop/"   $COMMON $GUARD
# ~/.config is EXCLUDED entirely (machine creds) — see §2.
```

**P5 — ENCRYPTED vault (privacy-absolute; NEVER plaintext):**
```bash
install -d -m 0700 "$HOME/.denton-vault-tmp"
tar czf - -C "$HOME/denton-projects" finance        | age -R ~/.config/age/recipients.txt > /tmp/finance.age
tar czf - -C "$HOME/denton-projects" denton-personal | age -R ~/.config/age/recipients.txt > /tmp/personal.age
# env-bundle: gather the §2 .env/secrets list explicitly, encrypt as one blob
tar czf - -C "$HOME/denton-projects" .env full/.env runpod/.env commands/.env dentoncode/.env \
     sandbox-dryrun/.env directives/.env dentoncode/nix/secrets 2>/dev/null \
   | age -R ~/.config/age/recipients.txt > /tmp/env-bundle.age
for f in finance personal env-bundle; do
  rclone copyto "/tmp/$f.age" "${HZ}denton-vault/$f.age" --checksum && shred -u "/tmp/$f.age"
done
# people/{kim,mike,kari}: default-encrypt unless a scan proves pure-code (then → system-repos bundle)
```
> `age -R recipients.txt` = asymmetric, Chase-only decrypt; the Hetzner key never sees plaintext.
> **No secret ever enters the nix store or a plaintext remote** — matches `denton-cloud.nix` ethos.

---

## 6. Verification + completion check ("everything is on Hetzner")

A migration is **done** only when every MIGRATE source passes a **checksum `rclone check`**
(no missing, no differs). Completion script (plan):

```bash
HZ="denton-obj:"; fail=0
chk(){ echo "== $1 =="; rclone check "$1" "${HZ}$2" --checksum --one-way 2>&1 | tee /tmp/chk.$$ \
       | grep -E '0 differences|errors? 0' >/dev/null || { echo "  !! MISMATCH"; fail=1; }; }

chk "$HOME/Dropbox"            cloud-sources/dropbox/
for rem in gdrive gdrive-kim-hurt-r gdrive-krimsonfixx gdrive-lebaron31 gdrive-nfuzionmusic gdrive-poisonlilac; do
  label="${rem#gdrive-}"; [ "$rem" = gdrive ] && label=primary
  rclone check "${rem}:" "${HZ}cloud-sources/gdrive/${label}/" --checksum --one-way 2>&1 | tail -2
done
chk "$HOME/.cache/huggingface" machine-archive/hf-models/
for d in mnt_archives synapse_archive synapse data models by_project old_projects misc archives; do
  chk "$HOME/denton-projects/_consolidated/staging/$d" "machine-archive/consolidated/$d/"; done

# repos present (bundle exists + is a valid bundle):
for r in dentoncode denton-qx music spyder-game wavez_music_ecosystem nix qx home comms voice; do
  rclone lsf "${HZ}system-repos/$r/" | grep -q "$r-.*\.bundle" && echo "$r: bundle ✓" || { echo "$r: MISSING"; fail=1; }
done

# vault present (encrypted blobs exist):
for f in finance personal env-bundle; do
  rclone lsf "${HZ}denton-vault/" | grep -q "$f.age" && echo "$f.age ✓" || { echo "$f.age MISSING"; fail=1; }
done

# privacy fuse — assert NO plaintext secret leaked anywhere on the bucket:
if rclone lsf "${HZ}" -R --include '.env' --include '*.key' --include '**/rclone.conf' | grep -q .; then
  echo "!! PRIVACY BREACH: plaintext secret found on Hetzner"; fail=1; fi

[ "$fail" = 0 ] && echo "✅ COMPLETE — everything verified on Hetzner" || echo "❌ INCOMPLETE — see mismatches"
```

**Report line on success:** sizes pushed (Dropbox 22G + gdrive×6 + HF 31G + consolidated ≈15G
post-dedup + repos), `rclone check` 0-diff on all, `0` plaintext secrets on-bucket, vault blobs
present. That is the auditable "everything is on Hetzner."

---

## 7. Open confirmations (ask Chase before P1/P5)

1. **`gdrive-ncrypted:`** — exclude entirely, or mirror into `denton-vault/` encrypted? (name implies
   sensitive; held by default.)
2. **`people/{kim,mike,kari}-projects`** — encrypt-by-default (assumed), or scan-and-plaintext if
   pure code?
3. **age recipient** — confirm `~/.config/age/recipients.txt` exists (Chase's pubkey) before P5; if
   not, generate `age-keygen` first (key stays local, by-name, never in chat).
4. **85G `Dropbox (Old)`** — OK to dedup-drop after the §3 one-way check proves it's a subset?

💡 commands: `lockwrite` this plan, then `gate` → `greenlight` P1/P5 with Chase; `mirror` to run.
