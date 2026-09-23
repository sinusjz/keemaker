# SSH Key-Kit

Generate, inspect and deploy SSH key pairs from PowerShell: to one server or a whole list, from an interactive menu or with scriptable command-line options.

```
  ╭────────────────────────────────────────────────╮
  │ SSH KEY KIT                                    │
  │ Generate · List · Deploy        v1.4.1         │
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
| [Posh-SSH](https://github.com/darkoperator/Posh-SSH) module | Only for deploying. Checked at the start of every deploy; if missing, you are offered a per-user installation (offline machines: see [Troubleshooting](#troubleshooting)). |

## Quick start

1. Download `SshKeyKit.ps1` somewhere (or clone this repository).
2. Open Windows Terminal and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\SshKeyKit.ps1      # one-off run without changing any setting
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

# Deploy to one server (the password is prompted, hidden, if -Password is omitted)
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
| `-Passphrase` | Optional key passphrase (at least 5 characters) as a **SecureString**. Prompted in the menu. |
| `-AddToAgent` | Load the generated key into ssh-agent. |
| `--host` (`--hostname`, `--server`, `--ip`) | Server to deploy to. |
| `--host-list` | Text file with many servers (see below). |
| `--port` | SSH port. Default: 22. |
| `--user` (`--username`) | Login user (default user for a host list). |
| `-Password` | Login password as a **SecureString**. Prompted (hidden) when omitted. |
| `--key` | Name or path of the public key to deploy. Default: `id_ed25519`. |
| `--target` | `auto` (default), `linux`, `esxi` or `mikrotik` (alias `routeros`). An explicit value skips OS detection. |
| `-DisablePasswordAuth` | Linux only: turn off SSH password login after a verified key login. |
| `-AcceptHostKey` | Trust an unknown server host key without asking. |
| `-Force` | Overwrite an existing key and skip confirmation prompts (including installing Posh-SSH). |
| `-Verbose` | Show every RouterOS command and answer while deploying (useful for troubleshooting). |
| `-Help` | Show a short usage summary. |

#### Passing passwords and passphrases

`-Password` and `-Passphrase` only accept a **SecureString**. Plain text (`-Password abc`, `--password abc`, `--password=abc`) is refused, because command-line values end up in shell history and process lists. Typical ways to supply one:

```powershell
# type it once, reuse it for several runs
$pw = Read-Host -AsSecureString "Router password"
.\SshKeyKit.ps1 -Deploy --host-list .\servers.txt --user admin -Password $pw

# from a credential object
$cred = Get-Credential admin
.\SshKeyKit.ps1 -Deploy --host 10.0.0.5 --user $cred.UserName -Password $cred.Password

# from a secret store (e.g. Microsoft.PowerShell.SecretManagement), if the secret is stored as a SecureString
.\SshKeyKit.ps1 -Deploy --host 10.0.0.5 --user admin -Password (Get-Secret -Name RouterAdmin)
```

If you omit them, the tool prompts with hidden input.

Exit codes: `0` success, `1` error or, in batch mode, at least one failed host.

## Deploying keys

### Targets and OS detection

With `--target auto` (the default) the tool logs in, asks the server what it is, and picks the matching procedure:

| Detected | Where the key goes | How |
|---|---|---|
| **Linux** (macOS/BSD hosts use the same layout; untested) | `~/.ssh/authorized_keys` | Creates `~/.ssh` (700) and the file (600), skips duplicates, repairs a missing trailing newline, restores SELinux contexts. |
| **VMware ESXi** | `/etc/ssh/keys-<user>/authorized_keys` | Same logic, then runs `/sbin/auto-backup.sh` so the key survives a reboot. ESXi only accepts ECDSA and RSA keys (see below). |
| **MikroTik RouterOS** | RouterOS user key store | Uploads the `.pub` over SFTP and runs `/user ssh-keys import`, then removes the temporary file. RSA works everywhere; Ed25519 only on newer RouterOS 7.x (7.12 or newer is reported); ECDSA is rejected. Default RouterOS settings only offer legacy SSH algorithms (see [below](#older-devices-that-only-offer-legacy-algorithms)). |

#### Key types per target

| Target | Ed25519 (default) | ECDSA | RSA |
|---|---|---|---|
| Linux | Yes | Yes | Yes |
| ESXi | **No, refused** | Yes (P-256, P-384, P-521) | Yes |
| MikroTik | RouterOS 7.12+ (reported; rejected on 7.8, accepted on 7.24.2); refused on 6.x | **No, refused** | Yes |

ESXi's SSH server is FIPS-restricted and does not support Ed25519 on any version ([Broadcom KB 394011](https://knowledge.broadcom.com/external/article/394011/not-possible-to-implement-sshed25519-key.html)); it accepts ECDSA (`nistp256/384/521`) and RSA (`rsa-sha2-256/512`). Because Ed25519 is this tool's default, keys for ESXi need to be generated explicitly:

```powershell
.\SshKeyKit.ps1 -Generate --type ecdsa --name id_esxi        # or: --type rsa --bits 4096
```

An incompatible key is refused **before anything is uploaded**: immediately when you pass `--target esxi`, or right after detection when the target is `auto`. In a batch, only the affected hosts fail. To reach a mixed estate with a single key, use RSA or ECDSA for the ESXi hosts, or split them into a separate list with their own key.

#### MikroTik notes

- **Use RSA unless you know the router is recent.** RouterOS rejects keys it cannot read with `unable to load key file (wrong format or bad passphrase)!`, both from the command line and in WinBox. That message almost always means an unsupported key type, not a damaged file: Ed25519 user keys are only accepted by newer 7.x releases (7.12 or newer is reported, sources differ), and ECDSA and security keys never are. The tool reads the RouterOS version before uploading: it refuses Ed25519 on RouterOS 6.x, warns on 7.0-7.11, and reports RouterOS's own answer instead of claiming success. If the version cannot be read it says so once (run with `-Verbose` to see the router's answer) and carries on.

  ```powershell
  .\SshKeyKit.ps1 -Generate --type rsa --bits 4096 --name id_mikrotik
  .\SshKeyKit.ps1 -Deploy --key id_mikrotik --host 192.168.88.1 --user admin
  ```

- **The import is verified, not assumed.** The tool waits until the uploaded file is complete on the router, imports it, and checks that the user's key count went up. If RouterOS answers with an error, the error is shown. If RouterOS answers with nothing but no new key appears, the tool says so (*did not report a new key*) instead of claiming success, and a failing key login then marks the host as failed. Run with `-Verbose` to see every command and answer. Observed on real routers: RouterOS 7.8 rejects Ed25519 user keys, 7.24.2 accepts them.
- **Password login stops for that user.** By default RouterOS stops accepting a user's password over SSH once the user has a key (see `/ip ssh always-allow-password-login`). Keep your current session open until the login test confirms key login works.

#### Detection

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

### Rebuilt or reinstalled servers (stale known_hosts entry)

If a server was rebuilt, reinstalled, or its IP address was reused, your `known_hosts` file still has the old fingerprint. The upload itself succeeds (Posh-SSH asks you to trust the new key separately, or `-AcceptHostKey` skips that), but the final login test then fails against the outdated local record with an error such as:

```text
Host key verification failed.
```

Since the new key was already trusted earlier in the same deploy, the tool removes the stale `known_hosts` entry automatically using the exact command OpenSSH itself provides (`ssh-keygen -R ...`), retries the login test once, and tells you what it did:

```text
! The locally cached SSH fingerprint for this server did not match (often means it was rebuilt or reinstalled). The outdated entry was replaced now that the new key has been confirmed.
+ Key-based login works.
```

If the fix itself fails (for example a read-only `known_hosts` file), the login test fails normally and the message above is not shown; run the `ssh-keygen -R ...` command OpenSSH gives you by hand.

### Older devices that only offer legacy algorithms

Some devices, notably RouterOS with default settings, only offer old SSH algorithms that current OpenSSH clients refuse by default:

```text
Unable to negotiate with x.x.x.x port 22: no matching MAC found. Their offer: hmac-sha1,hmac-md5
```

The key upload uses Posh-SSH, whose library still speaks these algorithms, so **the upload works**; only the OpenSSH-based login test is affected. The tool recognises this error (for a MAC, cipher, key exchange method or host key type), retries the login test allowing exactly the algorithms the device offers, and reports the outcome:

- a yellow warning *"Key login works, but only with legacy SSH algorithms"* with the `-o` options that are needed;
- the "Connect with" line then includes those options, so it can be copied as is;
- the retry only affects that single test connection (key authentication, no password is sent);
- `-DisablePasswordAuth` is refused for such servers.

The real fix is on the device. On RouterOS 7.x enable modern algorithms with:

```text
/ip ssh set strong-crypto=yes
```

Keep a console session open while you do this, because old SSH clients may stop working. (Reports say the setting does not help on RouterOS 6.x.) To connect by hand meanwhile, quote the value in PowerShell so the comma does not split the argument: `ssh -o "MACs=+hmac-sha1,hmac-md5" user@host`.

### Disabling password login (opt-in, Linux only)

`-DisablePasswordAuth` (or the question shown after a successful single deploy) turns off SSH password authentication on the server. It is deliberately conservative:

- It only runs **after key-based login was verified in the same run**. If the login test fails or is skipped, nothing is changed.
- It disables both `PasswordAuthentication` and keyboard-interactive authentication (otherwise PAM can still accept passwords).
- If `sshd_config` includes `sshd_config.d/*.conf`, a drop-in `00-sshkeykit.conf` is written; otherwise `sshd_config` is edited after making a `.kpt.bak` backup.
- The result is validated with `sshd -t` and reverted on error; sshd is reloaded and the effective settings are checked with `sshd -T`. Key login is re-tested afterwards.
- It runs as root, or through `sudo` using the login password (sent on stdin, never on a command line).

Keep your current session open until you have confirmed you can still log in. A `Match` block or an earlier config line can override the setting; the tool tells you when `sshd -T` still reports password login as enabled.

## Security notes

- Passwords and passphrases are never accepted as plain text on the command line: `-Password` / `-Passphrase` take a `SecureString`, and `--password=...` is rejected, so secrets stay out of shell history and process lists. See [Passing passwords and passphrases](#passing-passwords-and-passphrases).
- The passphrase is handed to `ssh-keygen` as a command-line argument, so it is briefly visible to other processes on the same machine. Acceptable on a single-user admin workstation; loading the key into ssh-agent means you type it once.
- **Host keys:** by default Posh-SSH shows the server fingerprint and asks you to confirm it. Answer *Y* only if it matches. `-AcceptHostKey` skips the question, so use it only on networks you trust. The final login test uses OpenSSH's `StrictHostKeyChecking=accept-new`, which records unknown host keys in your `known_hosts`.
- For devices that only offer legacy algorithms the login test may retry with those algorithms (see above). That connection uses key authentication only and runs a harmless `echo`, but the algorithms are weak, so fix the device rather than relying on it.
- Only the **public** key is ever uploaded. The password is used for the connection and, when disabling password login, for `sudo`.
- Recommended key types: Ed25519, or RSA with 3072+ bits. ESXi is the exception: use ECDSA or RSA there.

## Troubleshooting

| Symptom | Fix |
|---|---|
| *Running scripts is disabled on this system* | See [Quick start](#quick-start) (`Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`, `Unblock-File`). |
| *ssh-keygen was not found* | Install the OpenSSH Client, from an **administrator** PowerShell: `Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0` |
| *The ssh-agent service is disabled* | Once, from an administrator PowerShell: `Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent` |
| *Authentication failed for user@host* | Check username and password, and that password login is still enabled on the server (it is not after `-DisablePasswordAuth`). |
| *Key exchange failed ... host key was not trusted* | You answered *N* at the fingerprint prompt. Re-run and answer *Y*, or use `-AcceptHostKey`. |
| *Key-based login failed* | On the server check `PubkeyAuthentication`, the permissions of the home directory and `~/.ssh`, and SELinux contexts. |
| *Could not read the RouterOS version* | Harmless: the deployment continues. v1.3.5 and older could not read the version on real routers (a bare `get` prints nothing over SSH); fixed in 1.3.6. If it still appears, run with `-Verbose` and look at the answer for `:put [/system resource get version]`. |
| MikroTik: key uploaded but *not installed* / *did not report a new key* | Run `.\SshKeyKit.ps1 -Deploy ... -Verbose` and check on the router: `/file print`, `/user ssh-keys print`. Use an RSA key unless the router runs RouterOS 7.12 or newer (see [MikroTik notes](#mikrotik-notes)). |
| *The term 'New-SSHSession' is not recognized* (v1.3.4 and older) / *Could not install Posh-SSH* | The Posh-SSH module is missing. v1.3.5 offers to install it; if that fails (no access to the PowerShell Gallery, old PowerShellGet), install it yourself with `Install-Module -Name Posh-SSH -Scope CurrentUser -Force`. On an offline machine copy the `Posh-SSH` folder from the [Posh-SSH repository](https://github.com/darkoperator/Posh-SSH) into `$HOME\Documents\WindowsPowerShell\Modules\` (Windows PowerShell) or `$HOME\Documents\PowerShell\Modules\` (PowerShell 7). |
| *Unable to negotiate ... no matching MAC (or cipher, key exchange method, host key type) found* | The device only offers legacy SSH algorithms. See [Older devices](#older-devices-that-only-offer-legacy-algorithms). |
| *Host key verification failed* / *REMOTE HOST IDENTIFICATION HAS CHANGED* | Usually a rebuilt or reinstalled server. Handled automatically - see [Rebuilt or reinstalled servers](#rebuilt-or-reinstalled-servers-stale-known_hosts-entry). |
| *unable to load key file (wrong format or bad passphrase)!* (MikroTik) | RouterOS cannot read the key, usually because of its type. Deploy an RSA key instead (see [MikroTik notes](#mikrotik-notes)). |
| *Cannot process argument transformation on parameter 'Password'* (or `'Passphrase'`) | You passed plain text. Use a SecureString: `-Password (Read-Host -AsSecureString)`, a credential object or a secret store. |
| *ESXi does not support Ed25519 keys* | Generate an ECDSA or RSA key (`-Generate --type ecdsa`) and deploy that one. |
| *Could not identify the remote OS* | The device is not one of the supported types, or `uname` is unavailable. Pass `--target` explicitly if it is supported. |
| Odd symbols in the banner | The tool falls back to ASCII automatically outside Windows Terminal or VS Code. Windows Terminal is recommended. |

## Status and limitations

| Area | Status |
|---|---|
| Generate, List, ssh-agent loading | Verified |
| Deploy to Linux (single, batch, OS detection, disabling password login) | Verified |
| Deploy to VMware ESXi (ECDSA / RSA keys; Ed25519 is refused) | Verified |
| Deploy to MikroTik RouterOS (RSA; Ed25519 on RouterOS releases that support it) | Verified |
| Cisco IOS / IOS-XE, FortiGate | Not supported |

Other limits: the key folder is always `%USERPROFILE%\.ssh`; list files do not support IPv6 addresses.

## Contributing

- Keep line endings consistent. The repository includes a `.gitattributes` that stores `*.ps1` with LF (`* text=auto`, `*.ps1 text eol=lf`). Scripts embedded in the file and sent to servers are stripped of carriage returns, so a CRLF checkout on Windows works too.
- Static analysis: the password-related PSScriptAnalyzer rules are satisfied (secrets are `SecureString` only, and nothing uses `ConvertTo-SecureString -AsPlainText`). The coloured UI deliberately uses `Write-Host`, so expect `PSAvoidUsingWriteHost` notes.
- Keep the file pure ASCII (glyphs are built from character codes) so Windows PowerShell 5.1 never misreads its encoding.
- Please test changes against a real SSH server; the Linux paths were verified against OpenSSH with password auth, sudo, root and bulk lists.

## Changelog

| Version | Changes |
|---|---|
| **1.4.1** | Fix: a stale `known_hosts` entry (server rebuilt/reinstalled) made the login test fail with *Host key verification failed* even though the new key was already trusted; the tool now removes the outdated entry automatically and retries. |
| **1.4.0** | **Breaking:** `-Password` and `-Passphrase` are now `SecureString` parameters; plain text on the command line (`--password abc`, `--password=abc`) is refused. Removes the last `ConvertTo-SecureString -AsPlainText` use, so the password-related PSScriptAnalyzer rules are clean. |
| **1.3.6** | MikroTik: the RouterOS version is now read correctly (`:put [...]`, with a fallback and terminal-control-code stripping), so the Ed25519 version check and the *Detected:* line work on real routers. Marked verified on real hardware. |
| **1.3.5** | Fix: the Posh-SSH module was never loaded or offered for installation when it was missing, which ended in *The term 'New-SSHSession' is not recognized*. It is now checked at the start of every deploy, installed on request, and a failed installation shows the manual command. |
| **1.3.4** | MikroTik: waits for the uploaded file to be complete, verifies that the key was really added (no more false *Key installed*), reports leftover temp files, adds `-Verbose` diagnostics; an unconfirmed import with a failing key login is now a failed host. |
| **1.3.3** | MikroTik: an import that RouterOS refuses (e.g. *unable to load key file*) is now reported as an error instead of "Key installed"; Ed25519 is checked against the RouterOS version; note about password login stopping after a key is imported. |
| **1.3.2** | Login test recognises algorithm-negotiation failures on legacy devices (e.g. default RouterOS), retries with the offered algorithms and explains the fix. |
| **1.3.1** | Refuse Ed25519 keys for ESXi targets (unsupported by ESXi) with guidance to use ECDSA or RSA. |
| **1.3.0** | Dedicated *Batch deploy* menu entry with a host-list format explanation. |
| **1.2.0** | Automatic remote OS detection (`--target auto` is the default). |
| **1.1.0** | ssh-agent loading, opt-in password-login disabling, host-key hardening, ESXi and RouterOS targets, bulk deploy. CRLF-safe remote scripts. |
| **1.0.0** | Initial release: generate, list and deploy with interactive and inline modes. |
