# Secrets & recommended-but-BYO keys

Ethos: **all options, some recommended** — turnkey defaults you can swap. Nothing secret is
committed; this file tells you what to provide and where.

## 1. SSH access (recommended: set before cutover)

So the box is reachable the instant it boots — no console babysitting. In
`hosts/worker-01/configuration.nix`:

```nix
denton.access.sshKeys = [
  "ssh-ed25519 AAAA...your-pubkey... chase@macbook"
];
```

Applied to both `nvsble` and `denton`. SSH is **key-only** (passwords + root login off).

> Get your pubkey:  `cat ~/.ssh/id_ed25519.pub`  (macbook/brainstem). Generate if absent:
> `ssh-keygen -t ed25519`.

## 2. Tailscale auto-join (recommended: ephemeral auth key)

For unattended first-boot tailnet join. Generate an **ephemeral, pre-authorized** key at
<https://login.tailscale.com/admin/settings/keys>, drop it on the box (not in git):

```nix
denton.access.tailscaleAuthKeyFile = "/var/lib/secrets/tailscale.key";   # file contains: tskey-auth-...
```

```bash
sudo install -d -m 0700 /var/lib/secrets
printf 'tskey-auth-XXXX' | sudo tee /var/lib/secrets/tailscale.key >/dev/null
sudo chmod 0600 /var/lib/secrets/tailscale.key
```

Without it, run `sudo tailscale up` once at the console.

## 3. Model (recommended: a starter GGUF)

llama-server needs a GGUF. Either drop one at `denton.inference.model`
(`/var/lib/llama/models/default.gguf`) or set `modelUrl` to auto-fetch on first boot:

```nix
denton.inference.modelUrl = "https://huggingface.co/<repo>/resolve/main/<model>.Q4_K_M.gguf";
```

## 4. ⚠️ BEFORE the destructive reset — back up worker-01's current models

The reinstall **wipes the disk**, destroying the Ollama models on it — including your custom
**`denton-worker:v2` (8B)**. From a machine that can reach the worker (e.g. brainstem over Tailscale),
**while the old Ubuntu box is still up**:

```bash
# Save the custom model's recipe (so it can be rebuilt as GGUF for llama.cpp later)
curl -s http://100.102.176.60:11434/api/show -d '{"name":"denton-worker:v2"}' > denton-worker-v2.modelfile.json
# Copy the raw Ollama blob store off the box (has all GGUF weights), if you have SSH/rsync to it
# (worker SSH:22 is currently firewalled — pull from the console or open SSH first):
#   rsync -avz <worker>:~/.ollama/models/ ./worker01-ollama-backup/
```

> Ollama stores GGUF blobs under `~/.ollama/models/blobs`; the `*.modelfile.json` records the
> template/params. Keep both → you can re-serve `denton-worker:v2` under llama-server post-reset.

## 5. Hetzner rclone config (denton-cloud module)

`denton-cloud.nix` (imported by base → on every node) installs rclone and sets
`RCLONE_CONFIG=/var/lib/secrets/rclone.conf`. Deploy that config file once per node (out-of-band so
the Hetzner key + gdrive tokens never enter the nix store). From the node:

```bash
sudo install -d -m 0700 /var/lib/secrets
# pull the working config from brainstem (has denton-obj: + the gdrive remotes):
sudo scp -o StrictHostKeyChecking=accept-new nvsble@100.73.21.38:/home/nvsble/.config/rclone/rclone.conf /var/lib/secrets/rclone.conf
sudo chmod 0600 /var/lib/secrets/rclone.conf
rclone lsd denton-obj:cloud-sources/   # verify
```

Override the path per node with `denton.cloud.rcloneConfigFile = "...";`. Recommended later: manage
this file with sops-nix/agenix instead of a plaintext copy.

## Upgrade path (recommended later): sops-nix / agenix

For real secret management (encrypted-at-rest, in-repo), adopt **sops-nix** or **agenix** instead of
plaintext key files. Out of scope for the first turnkey boot; noted so we don't entrench plaintext.
