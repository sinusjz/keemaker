# SSH Key-Kit

Generate, inspect and deploy SSH key pairs from PowerShell: to one server or a whole list, from an interactive menu or with scriptable command-line options.

```
  ╭────────────────────────────────────────────────╮
  │ SSH KEY KIT                                    │
  │ Generate · List · Deploy        v1.3.0         │
  ╰────────────────────────────────────────────────╯

   [1] Generate      Create a new SSH key pair
   [2] List          Show public keys in your .ssh folder
   [3] Deploy        Upload a public key to one server
   [4] Batch deploy  Upload a public key to many servers from a list file
   [5] Exit
```

## Features

- **Generate** strong key pairs: Ed25519 by default, RSA or ECDSA on request, with an optional passphrase and a label.
- **List** the public keys in your `.ssh` folder with type, length, fingerprint, label and whether the private key is present.
- **Deploy** a public key to a server using a password, with no manual `ssh-copy-id` step (Windows has no `ssh-copy-id`).
  - The upload is idempotent (no duplicates), fixes permissions, and is followed by an automatic key-based login test.
  - The **remote OS is detected automatically** (Linux, ESXi, MikroTik RouterOS), so each server gets the right procedure.
- **Batch deploy** to many servers from a text file; one password prompt, per-host results and a summary.
- **Optionally disable SSH password login** on Linux servers, but only after key login has been verified.
- **Load keys into ssh-agent** right after generating them.
- Interactive menu **and** inline options (`-Generate --type ed25519 --bits 4096`) that work in scripts; exit code `0` on success, `1` on any error.
- Colour-coded output (green success, yellow warning, red error) with an ASCII fallback for legacy consoles.

## Requirements

| Requirement | Notes |
|---|---|
| Windows PowerShell 5.1 or PowerShell 7 | Also runs on PowerShell 7 for Linux/macOS (uses `~/.ssh`). No administrator rights needed. |
| OpenSSH Client | Provides `ssh-keygen`, `ssh` and `ssh-add`. Included in current Windows 10/11; see [Troubleshooting](#troubleshooting) if it is missing. |
| [Posh-SSH](https://github.com/darkoperator/Posh-SSH) module | Only for deploying. Offered for installation (current user only) the first time you deploy. |

## Quick start

1. Download `SshKeyKit.ps1` somewhere (or clone this repository).
2. Open PowerShell (Windows Terminal gives the best look) and run:

```powershell
.\SshKeyKit.ps1
```

If Windows blocks the script ("running scripts is disabled"):

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass .\KeyPairTool.ps1   # this window only
powershell -ExecutionPolicy Bypass -File .\KeyPairTool_v1.ps1                  # one-off run without changing any setting
Unblock-File .\SshKeyKit.ps1                                                   # if the file was downloaded
```

Keys are read from and written to `%USERPROFILE%\.ssh`.

## Interactive mode

Run the script without arguments.

| Menu entry | What it does |
|---|---|
| **Generate** | Asks for algorithm, length, label, file name and an optional passphrase (Enter for none), then offers to add the key to ssh-agent and to deploy it. |
| **List** | Shows every `*.pub` in `.ssh` with type, length, fingerprint, label and modification date. |
| **Deploy** | Pick a key, a target type (default: auto-detect), then host, port, username and password. |
| **Batch deploy** | Same as Deploy, but for a host-list file (see [Host-list file format](#host-list-file-format)). The password is asked once. |

## Command-line mode

Passing an action switch skips the menu. Options can be written PowerShell-style (`-Type rsa`) or GNU-style (`--type rsa` or `--type=rsa`).

```powershell
# Generate
.\SshKeyKit.ps1 -Generate                                    # ed25519, id_ed25519, label user@computer
.\SshKeyKit.ps1 -Generate --type ed25519 --byte 2048         # length is ignored for ed25519 (fixed)
.\SshKeyKit.ps1 -Generate --type rsa --bits 4096 --name id_prod --label "sina@work"

# List
.\SshKeyKit.ps1 -List

# Deploy to one server (password is prompted if --password is omitted)
.\SshKeyKit.ps1 -Deploy --host 10.0.0.5 --user admin --key id_ed25519

# Generate a key and deploy it in one go
.\SshKeyKit.ps1 -Generate -Deploy --host srv01 --user admin

# Deploy to many servers
.\SshKeyKit.ps1 -Deploy --host-list .\servers.txt --user admin
```

### Options

| Option | Description |
|---|---|
| `-Generate`, `-List`, `-Deploy` | Actions. Combine `-Generate -Deploy` to deploy the key that was just created. |
| `--type` | `ed25519` (default), `rsa` or `ecdsa`. |
| `--bits` (`--byte`, `--length`, `--size`) | RSA: 2048-16384, default 4096 (a warning is shown below 3072). ECDSA: 256, 384 or 521, default 384. Ignored for Ed25519. |
| `--label` (`--comment`) | Key comment. Default: `user@computer`. |
| `--name` | File name inside `.ssh`. Default: `id_<type>`. Letters, digits, `.`, `_` and `-` only. |
| `--passphrase` | Optional passphrase (at least 5 characters). Prefer the interactive prompt. |
| `-AddToAgent` | Load the generated key into ssh-agent. |
| `--host` (`--hostname`, `--server`, `--ip`) | Server to deploy to. |
| `--host-list` | Text file with many servers (see below). |
| `--port` | SSH port. Default: 22. |
| `--user` (`--username`) | Login user (default user for a host list). |
| `--password` | Login password. Prompted (hidden) when omitted, which is recommended. |
| `--key` | Name or path of the public key to deploy. Default: `id_ed25519`. |
| `--target` | `auto` (default), `linux`, `esxi` or `mikrotik` (alias `routeros`). An explicit value skips OS detection. |
| `-DisablePasswordAuth` | Linux only: turn off SSH password login after a verified key login. |
| `-AcceptHostKey` | Trust an unknown server host key without asking. |
| `-Force` | Overwrite an existing key and skip confirmation prompts (including installing Posh-SSH). |
| `-Help` | Show a short usage summary. |

Exit codes: `0` success, `1` error or, in batch mode, at least one failed host.

## Deploying keys

### Targets and OS detection

With `--target auto` (the default) the tool logs in, asks the server what it is, and picks the matching procedure:

| Detected | Where the key goes | How |
|---|---|---|
| **Linux** (macOS/BSD hosts use the same layout; untested) | `~/.ssh/authorized_keys` | Creates `~/.ssh` (700) and the file (600), skips duplicates, repairs a missing trailing newline, restores SELinux contexts. |
| **VMware ESXi** | `/etc/ssh/keys-<user>/authorized_keys` | Same logic, then runs `/sbin/auto-backup.sh` so the key survives a reboot. |
| **MikroTik RouterOS** | RouterOS user key store | Uploads the `.pub` over SFTP and runs `/user ssh-keys import`, then removes the temporary file. RSA keys work everywhere; Ed25519 needs a recent RouterOS 7.x; ECDSA is rejected. |

Detection uses `uname -s` as the main probe and the SSH banner as a cross-check. If the result is conclusive it is used; if not:

- in the **menu** you are asked to confirm (default *No* when banner and probe disagree);
- in **command-line and batch mode** the host fails with a message asking for an explicit `--target`.

A Cisco device is recognised and reported as *not supported yet*. Anything unidentifiable (for example a Windows host) produces a clear error.

### Host-list file format

A plain text file with one server per line. Blank lines and lines starting with `#` are ignored.

```text
# servers.txt

# host: uses the default user and port
192.168.1.10

# host:port: custom SSH port
srv02.lab.local:2222

# user@host: custom user
root@esx01

# user@host:port: both
backup@10.0.0.5:2200
```

- A `user@` or `:port` on a line overrides the defaults you give with `--user` / `--port` (or enter in the menu).
- The password is asked **once** and reused for every host.
- Each host is detected and handled separately, so Linux, ESXi and MikroTik servers can be mixed.
- A failing host never stops the others; a summary lists the result per host.
- Hostnames and IPv4 addresses only in list files; use `--host` for a single IPv6 host.

### Login test

After installing the key the tool tries a key-only login and reports the result. The test is skipped, with a hint, for passphrase-protected keys that are not loaded in ssh-agent (`ssh-add <key>` or generate with `-AddToAgent`).

### Disabling password login (opt-in, Linux only)

`-DisablePasswordAuth` (or the question shown after a successful single deploy) turns off SSH password authentication on the server. It is deliberately conservative:

- It only runs **after key-based login was verified in the same run**. If the login test fails or is skipped, nothing is changed.
- It disables both `PasswordAuthentication` and keyboard-interactive authentication (otherwise PAM can still accept passwords).
- If `sshd_config` includes `sshd_config.d/*.conf`, a drop-in `00-sshkeykit.conf` is written; otherwise `sshd_config` is edited after making a `.kpt.bak` backup.
- The result is validated with `sshd -t` and reverted on error; sshd is reloaded and the effective settings are checked with `sshd -T`. Key login is re-tested afterwards.
- It runs as root, or through `sudo` using the login password (sent on stdin, never on a command line).

Keep your current session open until you have confirmed you can still log in. A `Match` block or an earlier config line can override the setting; the tool tells you when `sshd -T` still reports password login as enabled.

## Security notes

- Prefer the interactive prompts over `--password` and `--passphrase`: command-line values end up in shell history (the tool warns you).
- The passphrase is handed to `ssh-keygen` as a command-line argument, so it is briefly visible to other processes on the same machine. Acceptable on a single-user admin workstation; loading the key into ssh-agent means you type it once.
- **Host keys:** by default Posh-SSH shows the server fingerprint and asks you to confirm it. Answer *Y* only if it matches. `-AcceptHostKey` skips the question, so use it only on networks you trust. The final login test uses OpenSSH's `StrictHostKeyChecking=accept-new`, which records unknown host keys in your `known_hosts`.
- Only the **public** key is ever uploaded. The password is used for the connection and, when disabling password login, for `sudo`.
- Recommended key types: Ed25519, or RSA with 3072+ bits.

## Troubleshooting

| Symptom | Fix |
|---|---|
| *Running scripts is disabled on this system* | See [Quick start](#quick-start) (`Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`, `Unblock-File`). |
| *ssh-keygen was not found* | Install the OpenSSH Client, from an **administrator** PowerShell: `Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0` |
| *The ssh-agent service is disabled* | Once, from an administrator PowerShell: `Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent` |
| *Authentication failed for user@host* | Check username and password, and that password login is still enabled on the server (it is not after `-DisablePasswordAuth`). |
| *Key exchange failed ... host key was not trusted* | You answered *N* at the fingerprint prompt. Re-run and answer *Y*, or use `-AcceptHostKey`. |
| *Key installed, but the login test failed* | On the server check `PubkeyAuthentication`, the permissions of the home directory and `~/.ssh`, and SELinux contexts. |
| *Could not identify the remote OS* | The device is not one of the supported types, or `uname` is unavailable. Pass `--target` explicitly if it is supported. |
| Odd symbols in the banner | The tool falls back to ASCII automatically outside Windows Terminal or VS Code. Windows Terminal is recommended. |

## Status and limitations

| Area | Status |
|---|---|
| Generate, List, ssh-agent loading | Verified |
| Deploy to Linux (single, batch, OS detection, disabling password login) | Verified |
| Deploy to VMware ESXi | Implemented; not yet verified on real hardware |
| Deploy to MikroTik RouterOS | Implemented; not yet verified on real hardware |
| Cisco IOS / IOS-XE, FortiGate | Not supported |

Other limits: the key folder is always `%USERPROFILE%\.ssh`; list files do not support IPv6 addresses.

## Contributing

- Keep line endings consistent. The repository includes a `.gitattributes` that stores `*.ps1` with LF (`* text=auto`, `*.ps1 text eol=lf`). Scripts embedded in the file and sent to servers are stripped of carriage returns, so a CRLF checkout on Windows works too.
- Keep the file pure ASCII (glyphs are built from character codes) so Windows PowerShell 5.1 never misreads its encoding.
- Please test changes against a real SSH server; the Linux paths were verified against OpenSSH with password auth, sudo, root and bulk lists.

## Changelog

| Version | Changes |
|---|---|
| **1.3.0** | Dedicated *Batch deploy* menu entry with a host-list format explanation. |
| **1.2.0** | Automatic remote OS detection (`--target auto` is the default). |
| **1.1.0** | ssh-agent loading, opt-in password-login disabling, host-key hardening, ESXi and RouterOS targets, bulk deploy. CRLF-safe remote scripts. |
| **1.0.0** | Initial release: generate, list and deploy with interactive and inline modes. |
