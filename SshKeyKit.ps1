#Requires -Version 5.1
<#
.SYNOPSIS
    SSH key pair generator and deployer (interactive menu + inline mode).

.DESCRIPTION
    Run without arguments to get the interactive menu:
        .\SshKeyKit.ps1

    Or use inline mode. Both PowerShell-style (-Type) and GNU-style (--type) options work:
        .\SshKeyKit.ps1 -Generate --type ed25519
        .\SshKeyKit.ps1 -Generate --type rsa --bits 4096 --name id_prod --label "sina@work"
        .\SshKeyKit.ps1 -List
        .\SshKeyKit.ps1 -Deploy --host 10.0.0.5 --user root --key id_ed25519
        .\SshKeyKit.ps1 -Generate -Deploy --host srv01 --user admin      # generate, then deploy that key
        .\SshKeyKit.ps1 -Deploy --host-list .\servers.txt --user admin  # many servers, password asked once
        .\SshKeyKit.ps1 -Deploy --host esx01 --user root                   # OS is detected automatically
        .\SshKeyKit.ps1 -Deploy --target esxi --host esx01 --user root    # ...or forced

    Options
        -Generate / -List / -Deploy       what to do (omit all for the menu)
        --type <ed25519|rsa|ecdsa>        default: ed25519
        --bits | --byte | --length <n>    RSA: 2048-16384 (default 4096) | ECDSA: 256/384/521 (default 384)
                                          (ignored for ed25519 - fixed length)
        --label <text>                    key comment          (default: user@computer)
        --name <file name>                file name in ~\.ssh  (default: id_<type>)
        -Passphrase <SecureString>        optional key passphrase (prompted in the menu)
        --host <ip|name>  --port <n>      deploy target        (port default: 22)
        --user <name>  -Password <SecureString>   deploy credentials (password is prompted, hidden, if omitted)
        --key <name|path>                 public key to deploy (default: id_ed25519)
        --target <auto|linux|esxi|mikrotik>  what kind of server you deploy to (default: auto = detect the
                                          remote OS after login; an explicit value skips detection)
        --host-list <file>                deploy to many hosts; one per line: host | host:port | user@host[:port]
                                          (lines starting with # are ignored; the password is asked once)
        -FromKnownHosts                    pick servers from ~\.ssh\known_hosts and deploy to them (always
                                          shows a picker to choose from; no "select all" yet)
        -AddToAgent                       after generating, load the key into ssh-agent
        -DisablePasswordAuth              Linux only: after a VERIFIED key login, turn off SSH password login
        -Force                            overwrite existing keys / skip confirmations
        -AcceptHostKey                    trust an unknown server host key without asking (use sparingly)
        -Help                             show this help

    Exit code: 0 = success, 1 = error (handy for automation).

.NOTES
    Requires the Windows "OpenSSH Client" feature (ssh-keygen). Deploying with a password uses the
    Posh-SSH module, which is installed for the current user on first use (with confirmation).
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Generate,
    [switch]$List,
    [switch]$Deploy,
    [switch]$Help,

    [string]$Type,

    [Alias('Length', 'Byte', 'Size')]
    [int]$Bits,

    [Alias('Comment')]
    [string]$Label,

    [string]$Name,

    [Alias('Host', 'Hostname', 'ComputerName', 'IP')]
    [string]$Server,

    [Alias('User')]
    [string]$Username,

    [securestring]$Password,
    [securestring]$Passphrase,
    [string]$Key,
    [int]$Port,
    [string]$Target,
    [string]$HostList,
    [switch]$FromKnownHosts,

    [switch]$Force,
    [switch]$AcceptHostKey,
    [switch]$AddToAgent,
    [switch]$DisablePasswordAuth,

    # Catches GNU-style options such as --type ed25519 --byte 2048
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ============================================================================
#  Globals & UI glyphs
# ============================================================================
$script:Version = '1.5.2'
$script:HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$script:SshDir  = Join-Path $script:HomeDir '.ssh'

# Unicode glyphs in modern terminals (Windows Terminal / VS Code), ASCII fallback otherwise.
$script:Unicode = [bool]($env:WT_SESSION -or $env:TERM_PROGRAM)
if ($script:Unicode) {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) }
    catch { $script:Unicode = $false }
}
$script:G = if ($script:Unicode) {
    @{
        TL = [string][char]0x256D; TR = [string][char]0x256E; BL = [string][char]0x2570; BR = [string][char]0x256F
        H  = [string][char]0x2500; V  = [string][char]0x2502
        Ok = [string][char]0x2713; Err = [string][char]0x2717; Warn = [string][char]0x25B2
        Info = [string][char]0x2022; Arrow = [string][char]0x203A; Dot = [string][char]0x00B7
    }
} else {
    @{ TL = '+'; TR = '+'; BL = '+'; BR = '+'; H = '-'; V = '|'; Ok = '+'; Err = 'x'; Warn = '!'; Info = 'i'; Arrow = '>'; Dot = '-' }
}

# ============================================================================
#  Output helpers
# ============================================================================
function Write-Ok   { param([string]$Message) Write-Host "  $($script:G.Ok) $Message"   -ForegroundColor Green }
function Write-Err  { param([string]$Message) Write-Host "  $($script:G.Err) $Message"  -ForegroundColor Red }
function Write-Warn { param([string]$Message) Write-Host "  $($script:G.Warn) $Message" -ForegroundColor Yellow }
function Write-Info { param([string]$Message) Write-Host "  $($script:G.Info) $Message" -ForegroundColor Cyan }

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "  $($script:G.Arrow) " -NoNewline -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor White
    Write-Host ('  ' + ($script:G.H * 46)) -ForegroundColor DarkGray
}

function Write-KV {
    param([string]$Key, [string]$Value, [string]$Color = 'White')
    Write-Host ('    {0}' -f $Key.PadRight(13)) -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor $Color
}

function Write-BoxRow {
    param([string]$Text, [string]$Color, [int]$Width)
    $padded = (' ' + $Text).PadRight($Width)
    Write-Host ('  ' + $script:G.V) -NoNewline -ForegroundColor Cyan
    Write-Host $padded -NoNewline -ForegroundColor $Color
    Write-Host $script:G.V -ForegroundColor Cyan
}

function Write-Banner {
    $g = $script:G
    $w = 48
    Write-Host ''
    Write-Host ('  ' + $g.TL + ($g.H * $w) + $g.TR) -ForegroundColor Cyan
    Write-BoxRow 'SSH KEY KIT' 'White' $w
    Write-BoxRow ("Generate $($g.Dot) List $($g.Dot) Deploy        v$($script:Version)") 'DarkGray' $w
    Write-Host ('  ' + $g.BL + ($g.H * $w) + $g.BR) -ForegroundColor Cyan
}

function Write-MenuItem {
    param([string]$Number, [string]$Title, [string]$Description, [int]$Width = 14)
    Write-Host "   [$Number] " -NoNewline -ForegroundColor Cyan
    Write-Host $Title.PadRight($Width) -NoNewline -ForegroundColor White
    Write-Host $Description -ForegroundColor DarkGray
}

# ============================================================================
#  Input helpers
# ============================================================================
function Read-Prompt {
    param(
        [Parameter(Mandatory)][string]$Label,
        [string]$Default = '',
        [scriptblock]$Validate,
        [switch]$AllowEmpty
    )
    while ($true) {
        Write-Host "  $($script:G.Arrow) " -NoNewline -ForegroundColor Cyan
        Write-Host $Label -NoNewline -ForegroundColor White
        if ($Default) { Write-Host " [$Default]" -NoNewline -ForegroundColor DarkGray }
        Write-Host ': ' -NoNewline -ForegroundColor DarkGray
        $value = "$(Read-Host)".Trim()
        if (-not $value) { $value = $Default }
        if (-not $value -and -not $AllowEmpty) { Write-Err 'This value is required.'; continue }
        if ($value -and $Validate) {
            $problem = & $Validate $value
            if ($problem) { Write-Err "$problem"; continue }
        }
        return $value
    }
}

function Read-Confirm {
    param([string]$Question, [bool]$Default = $false)
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        Write-Host "  $($script:G.Arrow) " -NoNewline -ForegroundColor Cyan
        Write-Host "$Question " -NoNewline -ForegroundColor White
        Write-Host "($hint): " -NoNewline -ForegroundColor DarkGray
        $answer = "$(Read-Host)".Trim().ToLower()
        if (-not $answer)                { return $Default }
        if ($answer -in 'y', 'yes')      { return $true }
        if ($answer -in 'n', 'no')       { return $false }
        Write-Err "Please answer 'y' or 'n'."
    }
}

function Read-Secret {
    param([string]$Label, [switch]$AllowEmpty)
    while ($true) {
        Write-Host "  $($script:G.Arrow) " -NoNewline -ForegroundColor Cyan
        Write-Host $Label -NoNewline -ForegroundColor White
        Write-Host ': ' -NoNewline -ForegroundColor DarkGray
        $secret = Read-Host -AsSecureString
        if ($secret.Length -eq 0 -and -not $AllowEmpty) { Write-Err 'This value is required.'; continue }
        return $secret
    }
}

function Select-Option {
    param([string]$Title, [object[]]$Options, [int]$Default = 1)
    Write-Host "  $Title" -ForegroundColor White
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host ('    [{0}] ' -f ($i + 1)) -NoNewline -ForegroundColor Cyan
        Write-Host ([string]$Options[$i].Text).PadRight(10) -NoNewline -ForegroundColor White
        Write-Host $Options[$i].Note -ForegroundColor DarkGray
    }
    $max = $Options.Count
    $sel = Read-Prompt -Label 'Choose' -Default "$Default" -Validate {
        param($v)
        if ($v -notmatch '^\d{1,3}$' -or [int]$v -lt 1 -or [int]$v -gt $max) { "Enter a number between 1 and $max." }
    }
    return $Options[[int]$sel - 1].Value
}

function Suspend-Menu {
    Write-Host ''
    Write-Host '  Press Enter to return to the menu...' -NoNewline -ForegroundColor DarkGray
    $null = Read-Host
}

function Invoke-Safely {
    param([scriptblock]$Action)
    try { & $Action }
    catch { Write-Host ''; Write-Err $_.Exception.Message }
}

# ============================================================================
#  Validators (return $null when OK, otherwise an error message)
# ============================================================================
function Test-KeyName  { param([string]$v) if ($v -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { 'Use letters, digits, dot, dash or underscore (max 64 characters).' } }
function Test-Label    { param([string]$v) if ($v.Length -gt 128 -or $v -match '[\x00-\x1F]') { 'Label must be 128 characters or fewer, without control characters.' } }
function Test-HostName { param([string]$v) if ($v -notmatch '^[A-Za-z0-9._:-]+$') { 'Enter a valid IP address or hostname.' } }
function Test-UserName { param([string]$v) if ($v -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.@-]*$') { 'Enter a valid username.' } }
function Test-PortNum  { param([string]$v) if ($v -notmatch '^\d{1,5}$' -or [int]$v -lt 1 -or [int]$v -gt 65535) { 'Port must be between 1 and 65535.' } }

# ============================================================================
#  Utilities
# ============================================================================
function Get-Tool {
    param([string]$Name)
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-SshKeygen {
    $path = Get-Tool 'ssh-keygen'
    if (-not $path) {
        throw ("ssh-keygen was not found. Install the Windows 'OpenSSH Client' feature (run as Administrator):`n" +
               "    Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0")
    }
    return $path
}

function Initialize-SshDir {
    if (-not (Test-Path -LiteralPath $script:SshDir)) {
        $null = New-Item -ItemType Directory -Path $script:SshDir -Force
    }
}

function Get-RootMessage {
    param($Exception)
    $e = $Exception
    while ($e.InnerException) { $e = $e.InnerException }
    return $e.Message
}

function ConvertTo-PlainText {
    param([securestring]$Secure)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

# Runs an executable with full control over quoting (avoids PowerShell's native-argument quirks,
# e.g. empty-string arguments being dropped in Windows PowerShell 5.1).
function Invoke-Native {
    param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @(), [string]$InputText = $null)

    $quoted = foreach ($a in $Arguments) {
        $s = $a -replace '(\\*)"', '$1$1\"'
        $s = $s -replace '(\\+)$', '$1$1'
        '"' + $s + '"'
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $File
    $psi.Arguments              = ($quoted -join ' ')
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    try { $proc = [System.Diagnostics.Process]::Start($psi) }
    catch { throw "Could not start '$File': $($_.Exception.Message)" }

    if ($InputText) { $proc.StandardInput.Write($InputText) }   # e.g. a sudo password (never on a command line)
    $proc.StandardInput.Close()                                 # never wait for more input
    $out = $proc.StandardOutput.ReadToEndAsync()
    $err = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $out.Result.Trim()
        StdErr   = $err.Result.Trim()
    }
}

# Uses a supplied value (validated), otherwise prompts (interactive), otherwise falls back to the default.
function Resolve-Value {
    param(
        $Given,
        [bool]$Interactive,
        [string]$Label,
        [string]$Default = '',
        [scriptblock]$Validate,
        [string]$MissingMessage = 'A required value is missing.'
    )
    if ($Given) {
        $problem = & $Validate "$Given"
        if ($problem) { throw "$problem" }
        return "$Given"
    }
    if ($Interactive) { return (Read-Prompt -Label $Label -Default $Default -Validate $Validate) }
    if ($Default)     { return $Default }
    throw $MissingMessage
}

function Resolve-Target {
    param([string]$Value)
    switch ("$Value".ToLower()) {
        'auto'     { return 'auto' }
        'linux'    { return 'linux' }
        'esxi'     { return 'esxi' }
        'mikrotik' { return 'mikrotik' }
        'routeros' { return 'mikrotik' }
        default    { throw "Unsupported target '$Value'. Use auto, linux, esxi or mikrotik." }
    }
}

# ============================================================================
#  ssh-agent helpers
# ============================================================================
function Test-KeyInAgent {
    param([string]$PubPath)
    $keygen = Get-Tool 'ssh-keygen'; $sshAdd = Get-Tool 'ssh-add'
    if (-not $keygen -or -not $sshAdd) { return $false }
    $fp = Invoke-Native -File $keygen -Arguments @('-l', '-f', $PubPath)
    if ($fp.ExitCode -ne 0 -or $fp.StdOut -notmatch '(SHA256:\S+)') { return $false }
    $wanted = $Matches[1]
    $loaded = Invoke-Native -File $sshAdd -Arguments @('-l')
    return ($loaded.ExitCode -eq 0 -and $loaded.StdOut.Contains($wanted))
}

function Add-KeyToAgent {
    param([string]$PrivPath)
    $sshAdd = Get-Tool 'ssh-add'
    if (-not $sshAdd) { throw 'ssh-add was not found (it ships with the OpenSSH Client).' }
    if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
        $svc = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
        if (-not $svc) { throw 'The ssh-agent service is not installed (it ships with the OpenSSH Client).' }
        if ($svc.Status -ne 'Running') {
            if ($svc.StartType -eq 'Disabled') {
                throw ("The ssh-agent service is disabled. Enable it once from an ADMIN PowerShell:`n" +
                       "    Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent")
            }
            try { Start-Service -Name 'ssh-agent' -ErrorAction Stop }
            catch { throw "Could not start the ssh-agent service (needs admin once): Start-Service ssh-agent" }
        }
    }
    Write-Info 'Adding key to ssh-agent (enter the passphrase if asked)...'
    $p = Start-Process -FilePath $sshAdd -ArgumentList ('"' + $PrivPath + '"') -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw 'ssh-add failed - the key was not loaded into the agent.' }
    Write-Ok 'Key loaded into ssh-agent (you will not be asked for the passphrase again this session).'
}

# ============================================================================
#  Key inventory
# ============================================================================
function Get-KeyInfo {
    if (-not (Test-Path -LiteralPath $script:SshDir)) { return @() }
    $keygen = Get-Tool 'ssh-keygen'
    $files  = @(Get-ChildItem -LiteralPath $script:SshDir -Filter '*.pub' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    $index  = 0
    foreach ($f in $files) {
        $index++
        $type = '?'; $bits = '?'; $fingerprint = '(unreadable)'; $comment = ''
        if ($keygen) {
            $r     = Invoke-Native -File $keygen -Arguments @('-l', '-f', $f.FullName)
            $first = @($r.StdOut -split "\r?\n")[0]
            if ($r.ExitCode -eq 0 -and $first -match '^(\d+)\s+(\S+)\s+(.*?)\s+\(([^)]+)\)$') {
                $bits = $Matches[1]; $fingerprint = $Matches[2]; $comment = $Matches[3]; $type = $Matches[4]
            }
        }
        [pscustomobject]@{
            Index       = $index
            Name        = $f.BaseName
            Path        = $f.FullName
            Type        = $type
            Bits        = $bits
            Fingerprint = $fingerprint
            Comment     = $comment
            HasPrivate  = (Test-Path -LiteralPath ($f.FullName -replace '\.pub$', ''))
            Modified    = $f.LastWriteTime
        }
    }
}

function Get-StrengthColor {
    param([string]$Type, $Bits)
    $b = 0
    [void][int]::TryParse("$Bits", [ref]$b)
    switch ($Type.ToUpper()) {
        'ED25519' { return 'Green' }
        'ECDSA'   { if ($b -ge 256) { return 'Green' } else { return 'Yellow' } }
        'RSA'     { if ($b -ge 3072) { return 'Green' } elseif ($b -ge 2048) { return 'Yellow' } else { return 'Red' } }
        default   { return 'Red' }
    }
}

function Show-KeyList {
    param([object[]]$Keys = @())
    Write-Section "Public keys in $($script:SshDir)"
    if (-not $Keys -or $Keys.Count -eq 0) {
        Write-Warn 'No public keys (*.pub) found.'
        Write-Info 'Generate one first (menu option 1, or: -Generate).'
        return
    }
    $nameWidth = ($Keys | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum + 2
    foreach ($k in $Keys) {
        Write-Host ('  [{0}] ' -f $k.Index) -NoNewline -ForegroundColor Cyan
        Write-Host $k.Name.PadRight($nameWidth) -NoNewline -ForegroundColor White
        Write-Host ('{0} {1}-bit' -f $k.Type, $k.Bits) -NoNewline -ForegroundColor (Get-StrengthColor $k.Type $k.Bits)
        Write-Host '   ' -NoNewline
        if ($k.HasPrivate) { Write-Host "$($script:G.Ok) private key present" -ForegroundColor Green }
        else               { Write-Host "$($script:G.Warn) public key only"    -ForegroundColor Yellow }
        Write-Host "      $($k.Fingerprint)" -ForegroundColor DarkGray
        $comment = if ($k.Comment) { $k.Comment } else { '(no label)' }
        Write-Host ("      {0} {1} {2:yyyy-MM-dd HH:mm}" -f $comment, $script:G.Dot, $k.Modified) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Info ("{0} key(s) found." -f $Keys.Count)
}

function Resolve-PubKey {
    param([string]$KeyRef)
    foreach ($base in @($KeyRef, (Join-Path $script:SshDir $KeyRef))) {
        $candidate = if ($base -like '*.pub') { $base } else { "$base.pub" }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    throw "Public key '$KeyRef' not found (searched the current folder and $($script:SshDir))."
}

# ============================================================================
#  Action: Generate
# ============================================================================
function Invoke-Generate {
    param([hashtable]$O, [bool]$Interactive)

    $keygen = Get-SshKeygen
    Initialize-SshDir
    Write-Section 'Generate key pair'

    # 1) Algorithm ------------------------------------------------------------
    $type = "$($O.Type)".ToLower()
    if (-not $type) {
        if ($Interactive) {
            $type = Select-Option -Title 'Algorithm' -Default 1 -Options @(
                @{ Value = 'ed25519'; Text = 'ed25519'; Note = 'recommended - modern, fast, compact' }
                @{ Value = 'rsa';     Text = 'rsa';     Note = 'maximum compatibility with legacy systems' }
                @{ Value = 'ecdsa';   Text = 'ecdsa';   Note = 'NIST curves (P-256 / P-384 / P-521)' }
            )
        } else { $type = 'ed25519' }
    }

    # 2) Length ---------------------------------------------------------------
    $bits = $null
    switch ($type) {
        'ed25519' {
            if ($O.Bits)             { Write-Warn 'ed25519 has a fixed length - the length option was ignored.' }
            elseif ($Interactive)    { Write-Info 'Length: fixed (256-bit) for ed25519.' }
        }
        'rsa' {
            if ($O.Bits) {
                $bits = [int]$O.Bits
                if ($bits -lt 2048 -or $bits -gt 16384) { throw 'RSA length must be between 2048 and 16384 bits.' }
            }
            elseif ($Interactive) {
                $bits = [int](Read-Prompt -Label 'Length in bits' -Default '4096' -Validate {
                    param($v)
                    if ($v -notmatch '^\d{1,5}$' -or [int]$v -lt 2048 -or [int]$v -gt 16384) { 'Enter a number between 2048 and 16384.' }
                })
            }
            else { $bits = 4096 }
            if ($bits -lt 3072) { Write-Warn "RSA-$bits is considered weak today - 3072 bits or more is recommended." }
        }
        'ecdsa' {
            if ($O.Bits) {
                $bits = [int]$O.Bits
                if ($bits -notin 256, 384, 521) { throw 'ECDSA length must be 256, 384 or 521.' }
            }
            elseif ($Interactive) {
                $bits = [int](Select-Option -Title 'Curve size' -Default 2 -Options @(
                    @{ Value = 256; Text = '256'; Note = 'P-256' }
                    @{ Value = 384; Text = '384'; Note = 'P-384 (recommended)' }
                    @{ Value = 521; Text = '521'; Note = 'P-521' }
                ))
            }
            else { $bits = 384 }
        }
        default { throw "Unsupported algorithm '$type'. Use ed25519, rsa or ecdsa." }
    }

    # 3) Label ----------------------------------------------------------------
    $label = Resolve-Value -Given $O.Label -Interactive $Interactive -Label 'Label (comment)' `
        -Default "$([Environment]::UserName)@$([Environment]::MachineName)" `
        -Validate { param($v) Test-Label $v }

    # 4) Name -----------------------------------------------------------------
    $name = Resolve-Value -Given $O.Name -Interactive $Interactive -Label 'File name' `
        -Default "id_$type" -Validate { param($v) Test-KeyName $v }
    $name = $name -replace '\.pub$', ''

    # 5) Passphrase (optional) -----------------------------------------------
    $passphrase = ''
    if ($O.Passphrase) {
        $passphrase = ConvertTo-PlainText $O.Passphrase
        if ($passphrase.Length -lt 5) { throw 'Passphrase must be at least 5 characters.' }
    }
    elseif ($Interactive) {
        while ($true) {
            $p1 = Read-Secret -Label 'Passphrase (Enter = none)' -AllowEmpty
            if ($p1.Length -eq 0) { Write-Warn 'No passphrase: anyone who gets the private key file can use it.'; break }
            if ($p1.Length -lt 5) { Write-Err 'Passphrase must be at least 5 characters.'; continue }
            $p2 = Read-Secret -Label 'Confirm passphrase'
            $plain1 = ConvertTo-PlainText $p1
            if ($plain1 -ne (ConvertTo-PlainText $p2)) { Write-Err 'Passphrases do not match.'; continue }
            $passphrase = $plain1
            break
        }
    }

    # Existing key? -----------------------------------------------------------
    $priv = Join-Path $script:SshDir $name
    $pub  = "$priv.pub"
    if ((Test-Path -LiteralPath $priv) -or (Test-Path -LiteralPath $pub)) {
        if ($O.Force) {
            Write-Warn "Overwriting existing key '$name'."
        }
        elseif ($Interactive) {
            Write-Warn "A key named '$name' already exists."
            if (-not (Read-Confirm 'Overwrite it? The old key will be lost' $false)) { Write-Info 'Cancelled.'; return $null }
        }
        else { throw "A key named '$name' already exists. Use -Force to overwrite it." }
        Remove-Item -LiteralPath $priv, $pub -Force -ErrorAction SilentlyContinue
    }

    # Generate ----------------------------------------------------------------
    $kgArgs = @('-q', '-t', $type)
    if ($bits) { $kgArgs += @('-b', "$bits") }
    $kgArgs += @('-C', $label, '-f', $priv, '-N', $passphrase)

    Write-Host ''
    Write-Info 'Generating key pair...'
    $r = Invoke-Native -File $keygen -Arguments $kgArgs
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $pub)) {
        $why = if ($r.StdErr) { $r.StdErr } else { "exit code $($r.ExitCode)" }
        throw "ssh-keygen failed: $why"
    }

    $info = @(Get-KeyInfo | Where-Object { $_.Name -eq $name }) | Select-Object -First 1
    Write-Ok 'Key pair generated successfully.'
    Write-Host ''
    Write-KV 'Type'        ($(if ($info) { "$($info.Type) $($info.Bits)-bit" } else { $type })) 'Green'
    Write-KV 'Label'       $label
    Write-KV 'Private key' $priv
    Write-KV 'Public key'  $pub
    if ($info) { Write-KV 'Fingerprint' $info.Fingerprint 'DarkGray' }
    Write-KV 'Passphrase'  ($(if ($passphrase) { 'set' } else { 'none' })) ($(if ($passphrase) { 'Green' } else { 'Yellow' }))

    # ssh-agent: load the key so the passphrase is only typed once per session
    $loadAgent = [bool]$O.AddToAgent
    if (-not $loadAgent -and $Interactive) {
        Write-Host ''
        $loadAgent = Read-Confirm 'Add this key to ssh-agent now?' ([bool]$passphrase)
    }
    if ($loadAgent) {
        try { Add-KeyToAgent -PrivPath $priv }
        catch { Write-Warn $_.Exception.Message }
    }
    return $pub
}

# ============================================================================
#  Action: Deploy
# ============================================================================
function Initialize-PoshSsh {
    # Already loaded, or loadable on demand from the module path?
    if (Get-Command New-SSHSession -ErrorAction SilentlyContinue) { return }
    if (Get-Module -ListAvailable -Name Posh-SSH) {
        Import-Module Posh-SSH -Global -ErrorAction Stop
        return
    }

    Write-Warn "The 'Posh-SSH' module (needed for password-based upload) is not installed."
    if (-not $Force) {
        if (-not (Read-Confirm 'Install it from the PowerShell Gallery for the current user?' $true)) {
            throw 'Posh-SSH is required to deploy with a password.'
        }
    }
    try {
        Write-Info 'Installing Posh-SSH...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force
        }
        Install-Module -Name Posh-SSH -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Import-Module Posh-SSH -Global -ErrorAction Stop
        if (-not (Get-Command New-SSHSession -ErrorAction SilentlyContinue)) {
            throw 'the module installed but its commands are not available - close this PowerShell window, open a new one and run the tool again'
        }
        Write-Ok 'Posh-SSH installed.'
    }
    catch {
        $nl = [Environment]::NewLine + '    '
        throw ("Could not install Posh-SSH: $(Get-RootMessage $_.Exception)" +
               $nl + 'Install it yourself, then run this tool again:' +
               $nl + 'Install-Module -Name Posh-SSH -Scope CurrentUser -Force')
    }
}

function Assert-HostReachable {
    param([string]$Server, [int]$Port, [int]$TimeoutMs = 6000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Server, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            throw "Connection to ${Server}:${Port} timed out - check the address, firewall and that SSH is running."
        }
        $client.EndConnect($async)

        # An SSH server announces itself first (e.g. "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3"). Used only as a hint for OS detection.
        $banner = ''
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 3000
            $buffer = New-Object byte[] 255
            $count  = $stream.Read($buffer, 0, $buffer.Length)
            if ($count -gt 0) { $banner = ([Text.Encoding]::ASCII.GetString($buffer, 0, $count) -split "\r?\n")[0].Trim() }
        }
        catch { $banner = '' }
        return $banner
    }
    catch [System.Net.Sockets.SocketException] {
        throw "Cannot reach ${Server}:${Port} - $($_.Exception.Message)"
    }
    finally { $client.Close() }
}

# --- remote OS detection ----------------------------------------------------------------------------
# Runs on the session that is already authenticated. `uname -s` is the main probe; the banner is only a
# cross-check. Returns Target = linux | esxi | mikrotik | cisco | $null (unknown).
function Get-RemoteOs {
    param($Session, [string]$Banner)

    $probe = Invoke-SSHCommand -SSHSession $Session -Command 'uname -s' -TimeOut 15
    $text  = ((@($probe.Output) + @($probe.Error)) -join ' ').Trim()

    $detected = $null
    if     ($text -match '^VMkernel')                                    { $detected = 'esxi' }
    elseif ($text -match '^(Linux|Darwin|FreeBSD|OpenBSD|NetBSD|SunOS)') { $detected = 'linux' }      # POSIX ~/.ssh layout
    elseif ($text -match 'bad command name')                             { $detected = 'mikrotik' }   # RouterOS CLI error
    elseif ($text -match '% ?Invalid|Invalid input|Unknown command')     { $detected = 'cisco' }      # IOS / IOS-XE CLI error

    $hint = $null
    if     ($Banner -match 'ROSSSH') { $hint = 'mikrotik' }
    elseif ($Banner -match 'Cisco')  { $hint = 'cisco' }

    $conflict   = [bool]($detected -and $hint -and $detected -ne $hint)
    $bannerOnly = $false
    if (-not $detected -and $hint) { $detected = $hint; $bannerOnly = $true }

    # A friendly label (best effort - never fails detection)
    $label = ''
    try {
        switch ($detected) {
            'linux' {
                $label = $text
                if ($text -match '^Linux') {
                    $os = Invoke-SSHCommand -SSHSession $Session -TimeOut 15 -Command '. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"'
                    $pretty = (@($os.Output) -join ' ').Trim()
                    if ($pretty) { $label = "$pretty (Linux)" }
                }
            }
            'esxi' {
                $v = Invoke-SSHCommand -SSHSession $Session -TimeOut 15 -Command 'vmware -v'
                $label = (@($v.Output) -join ' ').Trim()
                if (-not $label) { $label = 'VMware ESXi' }
            }
            'mikrotik' {
                $rv = Get-RosVersion -Session $Session
                $label = if ($rv -and $rv.Text.Length -lt 40) { "MikroTik RouterOS $($rv.Text)" } else { 'MikroTik RouterOS' }
            }
            'cisco' { $label = 'Cisco IOS / IOS-XE' }
        }
    }
    catch { }
    if (-not $label -and $detected) { $label = $detected }

    return [pscustomobject]@{ Target = $detected; Label = $label; Conflict = $conflict; BannerOnly = $bannerOnly; Probe = $text.Substring(0, [Math]::Min(80, $text.Length)) }
}

function Assert-KeyFitsTarget {
    param([string]$Target, [string]$PubLine)
    if ($Target -eq 'mikrotik') {
        if ($PubLine -match '^ecdsa-|^sk-') { throw 'RouterOS does not accept this key type (ECDSA and security keys are not supported). Use an RSA key, or Ed25519 on RouterOS 7.12 or newer.' }
    }
    if ($Target -eq 'esxi') {
        # ESXi's SSH server is FIPS-restricted to ECDSA (nistp256/384/521) and RSA (rsa-sha2-256/512) on all versions
        # (Broadcom KB 394011). Ed25519 can never authenticate there, so refuse before touching the server.
        if ($PubLine -match '^(ssh-ed25519|sk-ssh-ed25519@openssh\.com)\s') {
            throw ("ESXi does not support Ed25519 keys (all versions; its SSH server only accepts ECDSA and RSA - Broadcom KB 394011). " +
                   "Generate an ECDSA or RSA key instead, e.g.:  .\SshKeyKit.ps1 -Generate --type ecdsa --name id_esxi")
        }
        if ($PubLine -match '^sk-ecdsa-') { Write-Warn 'Security-key (sk-) keys are not in ESXi''s documented list of supported algorithms and will probably be rejected.' }
    }
}

# host list: one entry per line -> host | host:port | user@host[:port]   (# = comment)
# Parses ~/.ssh/known_hosts into a deduplicated list of {Server, Port}. known_hosts never stores usernames,
# so the caller always asks for one separately. Lines that cannot be turned into a concrete host are counted
# and skipped, never guessed at: hashed entries (HashKnownHosts, unreadable by design), @cert-authority /
# @revoked marker lines, wildcard patterns (*, ?) and negated patterns (!host, used only to carve exceptions
# out of a wildcard).
function Get-KnownHostEntries {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $seen = [ordered]@{}
    $hashed = 0; $skipped = 0
    foreach ($raw in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        $line = "$raw".Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $pattern = ($line -split '\s+', 2)[0]
        if (-not $pattern) { continue }
        if ($pattern -in '@cert-authority', '@revoked') { $skipped++; continue }
        foreach ($tok in ($pattern -split ',')) {
            $t = $tok.Trim()
            if (-not $t) { continue }
            if ($t.StartsWith('|1|')) { $hashed++; continue }
            if ($t.StartsWith('!') -or $t.Contains('*') -or $t.Contains('?')) { $skipped++; continue }
            $h = $t; $p = 22
            if ($t -match '^\[(?<h>.+)\]:(?<p>\d+)$') { $h = $Matches['h']; $p = [int]$Matches['p'] }
            # Guard against a corrupted or line-wrapped entry (e.g. an editor that wrapped a long line) spilling
            # raw key material into the host-pattern position: real hostnames/IPs never contain '+', '/', '='
            # (base64-only characters) and are never anywhere near this long.
            if ($h.Length -gt 100 -or $h -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9_.:-]*[A-Za-z0-9])?$') { $skipped++; continue }
            $key = "$h|$p"
            if (-not $seen.Contains($key)) { $seen[$key] = [pscustomobject]@{ Server = $h; Port = $p } }
        }
    }

    # Collapse a short hostname with its FQDN when a default search-domain would resolve them to the same
    # place (e.g. "nextcloud" and "nextcloud.se24.local" on the same port) - the FQDN is kept as unambiguous.
    $merged = 0
    $byPort = @{}
    foreach ($e in $seen.Values) {
        if (-not $byPort.ContainsKey($e.Port)) { $byPort[$e.Port] = @() }
        $byPort[$e.Port] += $e
    }
    $final = New-Object System.Collections.Generic.List[object]
    foreach ($port in $byPort.Keys) {
        $group = $byPort[$port]
        $fqdns = @($group | Where-Object { $_.Server.Contains('.') })
        foreach ($e in $group) {
            if (-not $e.Server.Contains('.')) {
                $prefix = $e.Server.ToLower() + '.'
                if (@($fqdns | Where-Object { $_.Server.ToLower().StartsWith($prefix) }).Count -gt 0) { $merged++; continue }
            }
            $final.Add($e)
        }
    }

    $entries = @($final | Sort-Object Server, Port)
    return [pscustomobject]@{ Entries = $entries; Hashed = $hashed; Skipped = $skipped; Merged = $merged }
}

function Show-KnownHostEntries {
    param([object[]]$Entries)
    $w = ($Entries | ForEach-Object { $_.Server.Length } | Measure-Object -Maximum).Maximum + 2
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        Write-Host ('  [{0}] ' -f ($i + 1)) -NoNewline -ForegroundColor Cyan
        Write-Host $Entries[$i].Server.PadRight($w) -NoNewline -ForegroundColor White
        $portNote = if ($Entries[$i].Port -ne 22) { "port $($Entries[$i].Port)" } else { '' }
        Write-Host $portNote -ForegroundColor DarkGray
    }
}

# Parses a selection string such as "1,3,5-7" against a list of that size. Returns an object with either
# Ok=$true and Indices (ascending, deduplicated) or Ok=$false and Error - never guess which shape a plain
# array return is, since PowerShell's automatic pipeline unrolling can flatten single-element wrapper arrays.
function ConvertFrom-IndexSelection {
    param([string]$Text, [int]$Max)
    $indices = [System.Collections.Generic.SortedSet[int]]::new()
    foreach ($part in ($Text -split ',')) {
        $p = $part.Trim()
        if (-not $p) { continue }
        if ($p -match '^(\d+)-(\d+)$') {
            $lo = [int]$Matches[1]; $hi = [int]$Matches[2]
            if ($lo -lt 1 -or $hi -gt $Max -or $lo -gt $hi) { return [pscustomobject]@{ Ok = $false; Error = "'$p' is not a valid range (1-$Max)." } }
            for ($n = $lo; $n -le $hi; $n++) { [void]$indices.Add($n) }
        }
        elseif ($p -match '^\d+$') {
            $n = [int]$p
            if ($n -lt 1 -or $n -gt $Max) { return [pscustomobject]@{ Ok = $false; Error = "'$p' is out of range (1-$Max)." } }
            [void]$indices.Add($n)
        }
        else { return [pscustomobject]@{ Ok = $false; Error = "'$p' is not a number or a range (e.g. 1,3,5-7)." } }
    }
    if ($indices.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Error = 'Select at least one server.' } }
    return [pscustomobject]@{ Ok = $true; Indices = @($indices) }
}

# Interactive picker: list every host found in known_hosts and let the person choose which ones to deploy to.
# There is deliberately no "select all" shortcut yet - every host is chosen by hand while this is new.
function Select-KnownHosts {
    Write-Section 'Servers from known_hosts'
    $khPath = Join-Path $script:SshDir 'known_hosts'
    $found = Get-KnownHostEntries -Path $khPath
    if (-not $found) { throw "No known_hosts file found at $khPath." }
    if ($found.Entries.Count -eq 0) {
        $why = if ($found.Hashed -gt 0) { " ($($found.Hashed) entries are hashed and cannot be read - see the README)" } else { '' }
        throw "No usable entries found in $khPath$why."
    }
    Show-KnownHostEntries -Entries $found.Entries
    Write-Host ''
    Write-Info ("{0} server(s) found." -f $found.Entries.Count)
    if ($found.Hashed  -gt 0) { Write-Info "$($found.Hashed) hashed entries were skipped (cannot be read; see the README)." }
    if ($found.Skipped -gt 0) { Write-Info "$($found.Skipped) other entries (certificate authorities, revoked, wildcard, or unreadable patterns) were skipped." }
    if ($found.Merged  -gt 0) { Write-Info "$($found.Merged) short hostname(s) were merged into their matching FQDN (e.g. 'nextcloud' -> 'nextcloud.example.local')." }
    Write-Warn 'known_hosts lists every server you have ever connected to, not just servers you manage. Only pick the ones you actually administer.'
    Write-Host ''

    $max = $found.Entries.Count
    while ($true) {
        Write-Host "  $($script:G.Arrow) " -NoNewline -ForegroundColor Cyan
        Write-Host 'Select servers to deploy to (e.g. 1,3,5-7): ' -NoNewline -ForegroundColor White
        $answer = "$(Read-Host)".Trim()
        $result = ConvertFrom-IndexSelection -Text $answer -Max $max
        if (-not $result.Ok) { Write-Err $result.Error; continue }
        return @($result.Indices | ForEach-Object { $found.Entries[$_ - 1] })
    }
}

function Read-HostList {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Host list '$Path' was not found." }
    $entries = @()
    $lineNo  = 0
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $lineNo++
        $t = "$line".Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        if ($t -notmatch '^(?:(?<u>[A-Za-z0-9_][A-Za-z0-9_.-]*)@)?(?<h>[A-Za-z0-9._-]+)(?::(?<p>\d{1,5}))?$') {
            throw "Host list line ${lineNo}: '$t' is not valid (use host, host:port or user@host[:port])."
        }
        $port = $null
        if ($Matches['p']) {
            $port = [int]$Matches['p']
            if ($port -lt 1 -or $port -gt 65535) { throw "Host list line ${lineNo}: port must be between 1 and 65535." }
        }
        $entries += [pscustomobject]@{ Server = $Matches['h']; Port = $port; User = $Matches['u'] }
    }
    if ($entries.Count -eq 0) { throw "Host list '$Path' contains no hosts." }
    return $entries
}

# --- per-target installers (each returns 'added' or 'present') --------------------------------
function Install-KeyLinux {
    param($Session, [string]$PubLine)
    # The key travels base64-encoded, so no quoting/escaping problems are possible.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($PubLine))
    $script = @'
umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys; if [ -s ~/.ssh/authorized_keys ] && [ -n "$(tail -c1 ~/.ssh/authorized_keys)" ]; then echo >> ~/.ssh/authorized_keys; fi; KEY=$(echo __B64__ | base64 -d); if grep -qxF -- "$KEY" ~/.ssh/authorized_keys; then echo KPT_PRESENT; else echo "$KEY" >> ~/.ssh/authorized_keys && echo KPT_ADDED; fi; command -v restorecon >/dev/null 2>&1 && restorecon -R ~/.ssh >/dev/null 2>&1; true
'@
    $cmd = "sh -c '" + $script.Replace('__B64__', $b64).Trim() + "'"
    $cmd = $cmd -replace "`r", ''      # a CRLF checkout must never leak carriage returns into the remote shell
    $res = Invoke-SSHCommand -SSHSession $Session -Command $cmd -TimeOut 30
    $out = ($res.Output -join "`n")
    if ($out -notmatch 'KPT_(ADDED|PRESENT)') {
        throw "Remote command failed (exit $($res.ExitStatus)). $((@($res.Error) -join ' ').Trim())"
    }
    if ($out -match 'KPT_PRESENT') { return 'present' } else { return 'added' }
}

function Install-KeyEsxi {
    param($Session, [string]$PubLine, [string]$Username)
    # ESXi keeps per-user keys in /etc/ssh/keys-<user>/authorized_keys and runs a BusyBox shell.
    # Only harmless characters are kept in the comment so the line is safe inside double quotes.
    $safe = $PubLine -replace '[^A-Za-z0-9+/=@._ -]', '_'
    $cmd = ('D=/etc/ssh/keys-{0}; F=$D/authorized_keys; mkdir -p $D; touch $F; ' +
            'if [ -s $F ] && [ -n "$(tail -c 1 $F)" ]; then echo >> $F; fi; ' +
            'if grep -qxF -- "{1}" $F; then echo KPT_PRESENT; else echo "{1}" >> $F && echo KPT_ADDED; fi; ' +
            'chmod 600 $F; /sbin/auto-backup.sh >/dev/null 2>&1; true') -f $Username, $safe
    $res = Invoke-SSHCommand -SSHSession $Session -Command $cmd -TimeOut 60
    $out = ($res.Output -join "`n")
    if ($out -notmatch 'KPT_(ADDED|PRESENT)') {
        throw "Remote command failed on ESXi (exit $($res.ExitStatus)). $((@($res.Error) -join ' ').Trim())"
    }
    if ($out -match 'KPT_PRESENT') { return 'present' } else { return 'added' }
}

# Runs a RouterOS console command over the exec channel and returns its (trimmed) text. Use -Verbose to see these.
function Invoke-RosValue {
    param($Session, [string]$Command)
    $r = Invoke-SSHCommand -SSHSession $Session -TimeOut 20 -Command $Command
    $text = ((@($r.Output) + @($r.Error)) -join ' ')
    # RouterOS may wrap answers in terminal control sequences; keep plain text only
    $text = ($text -replace '\x1b\[[0-9;?]*[A-Za-z]', '' -replace '[\x00-\x1F\x7F]', ' ' -replace '\s{2,}', ' ').Trim()
    Write-Verbose "RouterOS> $Command   =>   $text"
    return $text
}

# RouterOS version, e.g. 7.16.1 (stable). A bare `/system resource get version` prints nothing over an SSH exec channel
# (script context), so ask with :put and fall back to parsing `/system resource print`.
function Get-RosVersion {
    param($Session)
    $t = Invoke-RosValue -Session $Session -Command ':put [/system resource get version]'
    $m = [regex]::Match($t, '^[^\d]{0,3}(\d+)\.(\d+)')
    if ($m.Success) { return [pscustomobject]@{ Text = $t; Major = [int]$m.Groups[1].Value; Minor = [int]$m.Groups[2].Value } }

    $t = Invoke-RosValue -Session $Session -Command '/system resource print'
    $m = [regex]::Match($t, 'version:\s*(\d+)\.(\d+)')
    if ($m.Success) {
        $text = [regex]::Match($t, 'version:\s*(\S+(?:\s+\([^)]*\))?)').Groups[1].Value
        return [pscustomobject]@{ Text = $text; Major = [int]$m.Groups[1].Value; Minor = [int]$m.Groups[2].Value }
    }
    return $null
}

function Install-KeyMikrotik {
    param($Session, [hashtable]$Connect, [string]$PubPath, [string]$Username, [string]$PubLine = '')
    # RouterOS has no authorized_keys file: upload the .pub over SFTP, then import it for the user.

    # Ed25519 user keys: none on RouterOS 6; newer 7.x releases only (7.12+ is reported). Check before touching the device.
    if ($PubLine -match '^ssh-ed25519\s') {
        $rv = Get-RosVersion -Session $Session
        if ($rv) {
            if ($rv.Major -lt 7) {
                throw "RouterOS $($rv.Text) does not support Ed25519 keys. Use an RSA key instead:  .\SshKeyKit.ps1 -Generate --type rsa --bits 4096 --name id_mikrotik"
            }
            if ($rv.Major -eq 7 -and $rv.Minor -lt 12) {
                Write-Warn "RouterOS $($rv.Text) may reject Ed25519 keys (support is reported from 7.12; older releases answer 'unable to load key file'). If the import fails, use an RSA key."
            }
        }
        else { Write-Warn "Could not read the RouterOS version (run with -Verbose to see the router's answer). Ed25519 keys need RouterOS 7.12 or newer (reported); older versions reject them." }
    }

    $remoteName = 'kpt-import.pub'
    $tmp = Join-Path ([IO.Path]::GetTempPath()) $remoteName
    Copy-Item -LiteralPath $PubPath -Destination $tmp -Force
    $localSize = (Get-Item -LiteralPath $tmp).Length
    $countCmd  = ':put [:len [/user ssh-keys find where user="{0}"]]' -f $Username
    $sizeCmd   = ':put [/file get [find name="{0}"] size]' -f $remoteName
    $sftp = $null
    try {
        $t = Invoke-RosValue -Session $Session -Command $countCmd
        $keysBefore = if ($t -match '^\d+$') { [int]$t } else { $null }

        $sftp = New-SFTPSession @Connect
        Write-Verbose "SFTP: uploading $localSize bytes as '/$remoteName'"
        Set-SFTPItem -SessionId $sftp.SessionId -Path $tmp -Destination '/' -Force

        # RouterOS may still be writing the file when the upload call returns: wait until it is complete.
        $state = 'unknown'; $remoteSize = $null
        for ($i = 0; $i -lt 20; $i++) {
            $t = Invoke-RosValue -Session $Session -Command $sizeCmd
            if ($t -match '^\d+$') {
                $remoteSize = [int]$t
                if ($remoteSize -eq $localSize) { $state = 'ready'; break }
                $state = 'incomplete'
            }
            elseif ($t -match 'no such item|not found|invalid|bad |error|fail') { $state = 'missing' }
            else { $state = 'unknown'; break }        # unexpected format: cannot verify, carry on
            Start-Sleep -Milliseconds 500
        }
        if ($state -eq 'incomplete') { throw "The uploaded key file is incomplete on the router ($remoteSize of $localSize bytes). Please try again." }
        if ($state -eq 'missing') {
            $list = Invoke-RosValue -Session $Session -Command '/file print where name~"kpt"'
            throw "The uploaded key file '$remoteName' was not found on the router after the upload. Files matching 'kpt': $list"
        }

        $res = Invoke-SSHCommand -SSHSession $Session -TimeOut 30 `
                   -Command "/user ssh-keys import public-key-file=$remoteName user=$Username"
        $out = ((@($res.Output) + @($res.Error)) -join ' ').Trim()
        Write-Verbose "RouterOS> /user ssh-keys import public-key-file=$remoteName user=$Username   =>   $out"

        $t = Invoke-RosValue -Session $Session -Command $countCmd
        $keysAfter = if ($t -match '^\d+$') { [int]$t } else { $null }

        $null = Invoke-SSHCommand -SSHSession $Session -TimeOut 15 -Command "/file remove $remoteName"
        $left = Invoke-RosValue -Session $Session -Command (':put [:len [/file find where name="{0}"]]' -f $remoteName)
        if ($left -match '^[1-9]\d*$') { Write-Warn "The temporary file '$remoteName' is still on the router - remove it manually:  /file remove $remoteName" }

        # A successful import prints nothing. Anything else is either a known error or worth showing.
        if ($out -match 'already') { return 'present' }
        if ($out -match 'unable to load|wrong format|bad passphrase|fail|error|invalid|no such|not supported|bad command|syntax|not enough permissions|denied') {
            $msg = "RouterOS rejected the key: $out"
            if ($out -match 'unable to load|wrong format') {
                $nl = [Environment]::NewLine + '    '
                $msg += ($nl + 'RouterOS could not read this key. Its type is usually the reason: RSA works everywhere, Ed25519 needs RouterOS 7.12 or newer,' +
                         $nl + 'ECDSA and security keys are not supported. Generate an RSA key and deploy that one:' +
                         $nl + '.\SshKeyKit.ps1 -Generate --type rsa --bits 4096 --name id_mikrotik')
            }
            throw $msg
        }
        if ($out) { Write-Warn "RouterOS answered: $out  (not recognised as an error - the login test below will confirm)." }

        # Trust but verify: the user's key count must have gone up.
        if ($null -ne $keysBefore -and $null -ne $keysAfter -and $keysAfter -le $keysBefore) { return 'unconfirmed' }
        return 'added'
    }
    finally {
        if ($sftp) { $null = Remove-SFTPSession -SessionId $sftp.SessionId -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# --- login test ---------------------------------------------------------------------------------
# Parses OpenSSH's "no matching MAC/cipher/key exchange method/host key type found. Their offer: ..." error, which
# older devices (e.g. default RouterOS) trigger because they only offer algorithms modern OpenSSH refuses.
function Get-NegotiationHint {
    param([string]$StdErr)
    if ($StdErr -match 'no matching (?<what>MAC|cipher|key exchange method|host key type) found\. Their offer: (?<offer>\S+)') {
        $names = @{ 'mac' = 'MACs'; 'cipher' = 'Ciphers'; 'key exchange method' = 'KexAlgorithms'; 'host key type' = 'HostKeyAlgorithms' }
        $what  = $Matches['what']
        $offer = $Matches['offer']
        if ($what.ToLower() -eq 'key exchange method') {
            # OpenSSH lists protocol pseudo-entries here that are not valid in a KexAlgorithms setting
            $offer = (($offer -split ',') | Where-Object { $_ -notmatch '^(ext-info-[cs]|kex-strict-[cs]-v00@openssh\.com)$' }) -join ','
            if (-not $offer) { return $null }
        }
        return [pscustomobject]@{ What = $what; Offer = $offer; Option = $names[$what.ToLower()] }
    }
    return $null
}

# OpenSSH prints the exact removal command when a known host's key no longer matches, e.g. after a server
# rebuild or a reassigned IP: ssh-keygen -f '/home/x/.ssh/known_hosts' -R '[host]:port'. Reusing OpenSSH's own
# command is more reliable than building one ourselves (it is already correct for hashed known_hosts files,
# IPv6, non-default ports and custom file locations).
function Get-StaleHostKeyFix {
    param([string]$StdErr)
    if ($StdErr -match "ssh-keygen -f '(?<file>[^']+)' -R '(?<pattern>[^']+)'") {
        return [pscustomobject]@{ File = $Matches['file']; Pattern = $Matches['pattern'] }
    }
    return $null
}

function Invoke-KeyProbe {
    param([string]$Ssh, [string]$Priv, [string]$Server, [int]$Port, [string]$Username, [string]$Target, [string[]]$ExtraArgs = @())
    $probe = if ($Target -eq 'mikrotik') { ':put KPT_OK' } else { 'echo KPT_OK' }
    $sshArgs = @('-o', 'BatchMode=yes', '-o', 'PasswordAuthentication=no', '-o', 'IdentitiesOnly=yes',
                 '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=10') + $ExtraArgs +
               @('-p', "$Port", '-i', $Priv, "$Username@$Server", $probe)
    $t = Invoke-Native -File $Ssh -Arguments $sshArgs
    return [pscustomobject]@{ Ok = ($t.ExitCode -eq 0 -and $t.StdOut -match 'KPT_OK'); StdErr = $t.StdErr; ExitCode = $t.ExitCode }
}

# returns 'ok' | 'legacy' (works only with legacy algorithms) | 'failed' | 'skipped'
function Test-KeyLogin {
    param([string]$PubPath, [string]$Server, [int]$Port, [string]$Username, [string]$Target)
    $script:NegotiationOptions = ''
    $priv   = $PubPath -replace '\.pub$', ''
    $ssh    = Get-Tool 'ssh'
    $keygen = Get-Tool 'ssh-keygen'
    if (-not $ssh -or -not $keygen -or -not (Test-Path -LiteralPath $priv)) { return 'skipped' }

    $needsPassphrase = (Invoke-Native -File $keygen -Arguments @('-y', '-P', '', '-f', $priv)).ExitCode -ne 0
    if ($needsPassphrase -and -not (Test-KeyInAgent -PubPath $PubPath)) {
        Write-Info 'Private key has a passphrase and is not loaded in ssh-agent - login test skipped.'
        Write-Info "Load it with:  ssh-add `"$priv`"   (or generate with -AddToAgent)"
        return 'skipped'
    }
    Write-Info 'Testing key-based login...'
    $r = Invoke-KeyProbe -Ssh $ssh -Priv $priv -Server $Server -Port $Port -Username $Username -Target $Target
    if ($r.Ok) { Write-Ok 'Key-based login works.'; return 'ok' }

    # Two recoverable mismatches, retried on the same test connection:
    #  - a stale known_hosts entry (the server was rebuilt or its IP was reassigned since the last visit;
    #    the new key was already trusted when this deploy started, so the old local record is simply outdated)
    #  - some devices only offer legacy algorithms that modern OpenSSH refuses by default
    $extra = @(); $shown = @(); $found = @(); $staleFixed = $false
    for ($i = 0; $i -lt 5 -and -not $r.Ok; $i++) {
        $stale = Get-StaleHostKeyFix -StdErr $r.StdErr
        if ($stale -and -not $staleFixed) {
            Write-Verbose "Stale known_hosts entry: $($stale.Pattern) in $($stale.File)"
            $rk = Invoke-Native -File $keygen -Arguments @('-f', $stale.File, '-R', $stale.Pattern)
            Write-Verbose "ssh-keygen -R => exit $($rk.ExitCode)  $($rk.StdOut) $($rk.StdErr)"
            if ($rk.ExitCode -ne 0) { break }
            $staleFixed = $true
            $r = Invoke-KeyProbe -Ssh $ssh -Priv $priv -Server $Server -Port $Port -Username $Username -Target $Target -ExtraArgs $extra
            continue
        }
        $hint = Get-NegotiationHint -StdErr $r.StdErr
        if (-not $hint) { break }
        $extra += @('-o', "$($hint.Option)=+$($hint.Offer)")
        $shown += "-o `"$($hint.Option)=+$($hint.Offer)`""
        $found += "$($hint.What): $($hint.Offer)"
        $r = Invoke-KeyProbe -Ssh $ssh -Priv $priv -Server $Server -Port $Port -Username $Username -Target $Target -ExtraArgs $extra
    }
    if ($r.Ok -and $staleFixed) {
        Write-Warn 'The locally cached SSH fingerprint for this server did not match (often means it was rebuilt or reinstalled). The outdated entry was replaced now that the new key has been confirmed.'
        if ($extra.Count -eq 0) { Write-Ok 'Key-based login works.'; return 'ok' }
    }
    if ($r.Ok -and $extra.Count -gt 0) {
        $script:NegotiationOptions = ($shown -join ' ')
        Write-Warn "Key login works, but only with legacy SSH algorithms that OpenSSH refuses by default ($($found -join '; '))."
        Write-Info 'This is not a problem with the key or the upload. The device just offers old, weak algorithms.'
        if ($Target -eq 'mikrotik') { Write-Info 'On RouterOS 7.x you can enable modern ones:  /ip ssh set strong-crypto=yes   (keep a console session open; it can lock out old SSH clients)' }
        else                        { Write-Info 'Recommended: enable modern SSH algorithms on the device.' }
        Write-Info "To connect until then, add:  $($script:NegotiationOptions)"
        return 'legacy'
    }
    $why = if ($r.StdErr) { ($r.StdErr -split "\r?\n")[-1] } else { "exit code $($r.ExitCode)" }
    Write-Warn "Key-based login failed: $why"
    if ($Target -eq 'mikrotik') { Write-Info 'On the router check that the user has the key:  /user ssh-keys print   (run this tool with -Verbose for details).' }
    else                        { Write-Info 'Check PubkeyAuthentication, SELinux contexts and home-directory permissions on the server.' }
    return 'failed'
}

# --- turn off SSH password login (Linux only, only after a verified key login) -----------------
function Disable-PasswordAuth {
    param([string]$Server, [int]$Port, [string]$Username, [securestring]$Secure, [string]$PubPath)

    $ssh  = Get-Tool 'ssh'
    $priv = $PubPath -replace '\.pub$', ''
    # Runs as root on the server. Uses a drop-in file when sshd_config includes sshd_config.d (first value wins,
    # so "00-" sorts first); otherwise edits sshd_config with a backup. Validates with sshd -t and reverts on error.
    $remote = @'
MAIN=/etc/ssh/sshd_config
DROP=/etc/ssh/sshd_config.d
CONF=$DROP/00-sshkeykit.conf
SSHD=$(command -v sshd || echo /usr/sbin/sshd)
if "$SSHD" -T 2>/dev/null | grep -qi "^kbdinteractiveauthentication"; then KBD=KbdInteractiveAuthentication; else KBD=ChallengeResponseAuthentication; fi
if [ -d "$DROP" ] && grep -qiE "^[[:space:]]*Include[[:space:]].*sshd_config\.d" "$MAIN"; then
  MODE=dropin
  printf "PasswordAuthentication no\n%s no\n" "$KBD" > "$CONF"
else
  MODE=main
  cp -p "$MAIN" "$MAIN.kpt.bak"
  sed -i -E "s/^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]].*/#&/" "$MAIN"
  printf "\nPasswordAuthentication no\n%s no\n" "$KBD" >> "$MAIN"
fi
if ! "$SSHD" -t 2>/dev/null; then
  if [ "$MODE" = dropin ]; then rm -f "$CONF"; else cp -p "$MAIN.kpt.bak" "$MAIN"; fi
  echo KPT_PW_FAILED_TEST; exit 1
fi
(systemctl reload sshd || systemctl reload ssh || service sshd reload || service ssh reload) >/dev/null 2>&1 || { echo KPT_PW_RELOAD_FAILED; exit 1; }
if "$SSHD" -T 2>/dev/null | grep -qiE "^(passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication) yes"; then echo KPT_PW_NOT_EFFECTIVE; else echo KPT_PW_DISABLED; fi
'@
    $remote = $remote -replace "`r", ''   # a CRLF checkout must never leak carriage returns into the remote shell
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remote))
    # root runs it directly; everyone else through sudo, with the password fed on stdin (never on a command line)
    $cmd = 'S=; [ "$(id -u)" -ne 0 ] && S="sudo -S"; $S sh -c "$(echo ' + $b64 + ' | base64 -d)"'

    Write-Info 'Disabling SSH password login (uses root / sudo)...'
    $r = Invoke-Native -File $ssh -InputText ((ConvertTo-PlainText $Secure) + "`n") -Arguments @(
        '-o', 'BatchMode=yes', '-o', 'PasswordAuthentication=no', '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=10',
        '-p', "$Port", '-i', $priv, "$Username@$Server", $cmd)

    switch -Regex ($r.StdOut) {
        'KPT_PW_DISABLED' {
            Write-Ok 'SSH password login is now disabled (password and keyboard-interactive).'
            $again = Invoke-KeyProbe -Ssh $ssh -Priv $priv -Server $Server -Port $Port -Username $Username -Target 'linux'
            if ($again.Ok) { Write-Ok 'Key-based login re-tested after the change: still works.' }
            else           { Write-Warn 'Key login could NOT be re-tested after the change - keep your current session open and check it.' }
            return
        }
        'KPT_PW_NOT_EFFECTIVE' { Write-Warn 'The setting was written, but sshd still reports password login enabled (a Match block or an earlier config line wins). Check sshd -T on the server.'; return }
        'KPT_PW_FAILED_TEST'   { Write-Warn 'sshd rejected the new configuration; it was reverted. Password login is unchanged.'; return }
        'KPT_PW_RELOAD_FAILED' { Write-Warn 'The config was written, but sshd could not be reloaded. Reload it manually (systemctl reload sshd).'; return }
    }
    $why = if ($r.StdErr) { ($r.StdErr -split "\r?\n")[-1] } else { "exit code $($r.ExitCode)" }
    Write-Warn "Could not disable password login (needs root or working sudo): $why"
}

# --- one host, start to finish ------------------------------------------------------------------
function Install-KeyOnHost {
    param(
        [string]$Target, [string]$Server, [int]$Port, [string]$Username, [securestring]$Secure,
        [string]$PubPath, [string]$PubLine, [bool]$AcceptKey, [bool]$DisablePw, [bool]$AskDisablePw, [bool]$Ask = $false
    )

    Initialize-PoshSsh
    Write-Info "Checking ${Server}:${Port} ..."
    $banner = Assert-HostReachable -Server $Server -Port $Port
    Write-Ok 'Host is reachable.'
    $wasAuto = ($Target -eq 'auto')
    $os = $null

    $credential = New-Object System.Management.Automation.PSCredential($Username, $Secure)
    $connect = @{
        ComputerName      = $Server
        Port              = $Port
        Credential        = $credential
        ConnectionTimeout = 15
        ErrorAction       = 'Stop'
    }
    if ($AcceptKey) { $connect['AcceptKey'] = $true }

    $session = $null
    $status  = 'added'
    try {
        Write-Info "Connecting as ${Username}@${Server} ..."
        try { $session = New-SSHSession @connect }
        catch {
            $msg = Get-RootMessage $_.Exception
            if     ($msg -match 'Permission denied|Authentication|auth') { throw "Authentication failed for ${Username}@${Server} - check the username/password and that password login is enabled on the server." }
            elseif ($msg -match 'timed out|timeout')                     { throw "Connection to ${Server}:${Port} timed out." }
            elseif ($msg -match 'Key exchange|Object reference')         { throw "Key exchange failed - the server's host key was probably not trusted. Answer Y at the fingerprint prompt, or use -AcceptHostKey. (Otherwise client and server share no common algorithms.)" }
            else                                                         { throw "SSH connection failed: $msg" }
        }
        Write-Ok 'Authenticated.'

        if ($wasAuto) {
            Write-Info 'Detecting the remote OS...'
            $os = Get-RemoteOs -Session $session -Banner $banner
            if (-not $os.Target) {
                throw ("Could not identify the remote OS (uname replied: $($os.Probe)). Supported targets: linux, esxi, mikrotik - " +
                       "re-run with --target <type> to choose one yourself.")
            }
            if ($os.Target -eq 'cisco') { throw "Detected a Cisco device ($($os.Label)) - Cisco deployment is not supported yet." }
            Write-Ok "Detected: $($os.Label)"
            $unsure = ($os.Conflict -or $os.BannerOnly)
            if ($unsure -and -not $Ask) {
                throw "OS detection is not conclusive (SSH banner: $banner; uname replied: $($os.Probe)). Re-run with --target linux|esxi|mikrotik."
            }
            if ($unsure) { Write-Warn "Detection is not conclusive (SSH banner: $banner; uname replied: $($os.Probe))." }
            if ($Ask -and -not (Read-Confirm "Deploy as '$($os.Target)'?" (-not $unsure))) {
                throw 'Cancelled - re-run with --target to choose the deployment type yourself.'
            }
            $Target = $os.Target
            Assert-KeyFitsTarget -Target $Target -PubLine $PubLine
            if ($DisablePw -and $Target -ne 'linux') { Write-Warn "-DisablePasswordAuth only applies to Linux targets - ignored for this $Target host."; $DisablePw = $false }
        }

        Write-Info 'Installing public key...'
        switch ($Target) {
            'esxi'     { $status = Install-KeyEsxi     -Session $session -PubLine $PubLine -Username $Username }
            'mikrotik' { $status = Install-KeyMikrotik -Session $session -Connect $connect -PubPath $PubPath -Username $Username -PubLine $PubLine }
            default    { $status = Install-KeyLinux    -Session $session -PubLine $PubLine }
        }
        $where = switch ($Target) { 'esxi' { "/etc/ssh/keys-$Username/authorized_keys" } 'mikrotik' { "RouterOS user '$Username'" } default { '~/.ssh/authorized_keys' } }
        if     ($status -eq 'present')     { Write-Ok 'Key was already authorized on the server - nothing changed.' }
        elseif ($status -eq 'unconfirmed') { Write-Warn "RouterOS did not report a new key for '$Username' (it may already be present, or the import silently failed). The login test below decides. Use -Verbose for details." }
        else                               { Write-Ok "Key installed ($where) for ${Username}@${Server}." }
        if ($status -eq 'added' -and $Target -eq 'mikrotik') {
            Write-Info "RouterOS normally stops accepting this user's password over SSH once the user has a key (setting: /ip ssh always-allow-password-login). Keep your current session open until key login is confirmed."
        }
    }
    finally {
        if ($session) { $null = Remove-SSHSession -SSHSession $session -ErrorAction SilentlyContinue }
    }

    $login = Test-KeyLogin -PubPath $PubPath -Server $Server -Port $Port -Username $Username -Target $Target

    if ($Target -eq 'linux' -and ($DisablePw -or $AskDisablePw)) {
        if ($login -ne 'ok') {
            $why = if ($login -eq 'legacy') { 'this server only works with legacy SSH algorithms, which this tool does not use for changing server settings' }
                   else                     { 'key-based login has not been verified, and disabling it now could lock you out' }
            Write-Warn "Password login was NOT disabled: $why."
        }
        else {
            $go = $DisablePw
            if (-not $go) {
                Write-Host ''
                Write-Info 'Key login just worked, so turning off password login is safe. This disables password AND keyboard-interactive logins.'
                $go = Read-Confirm 'Disable SSH password login on this server now?' $false
            }
            if ($go) { Disable-PasswordAuth -Server $Server -Port $Port -Username $Username -Secure $Secure -PubPath $PubPath }
        }
    }
    return [pscustomobject]@{ Status = $status; Login = $login; Target = $Target; SshOptions = $script:NegotiationOptions }
}

function Show-HostListHelp {
    $g = $script:G
    Write-Host ''
    Write-Host '  Host-list file format' -ForegroundColor White
    Write-Host '  A plain text file with one server per line. Blank lines and lines starting with # are ignored.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '      # example: servers.txt' -ForegroundColor DarkGray
    $examples = @(
        @('192.168.1.10',         'host',            '(uses the default user and port)'),
        @('srv02.lab.local:2222', 'host:port',       '(custom SSH port)'),
        @('root@esx01',           'user@host',       '(custom user)'),
        @('backup@10.0.0.5:2200', 'user@host:port',  '(both)')
    )
    foreach ($row in $examples) {
        Write-Host '      ' -NoNewline
        Write-Host $row[0].PadRight(26) -NoNewline -ForegroundColor Cyan
        Write-Host ($row[1].PadRight(16) + $row[2]) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host "  $($g.Dot) A user@ or :port on a line overrides the defaults you enter below." -ForegroundColor Gray
    Write-Host "  $($g.Dot) The password is asked once and reused for every host." -ForegroundColor Gray
    Write-Host "  $($g.Dot) With target 'auto', each server's OS is detected separately, so Linux, ESXi" -ForegroundColor Gray
    Write-Host '    and MikroTik hosts can be mixed in one list.' -ForegroundColor Gray
    Write-Host "  $($g.Dot) A failing host does not stop the others; a summary is shown at the end." -ForegroundColor Gray
    Write-Host ''
}

function Invoke-Deploy {
    param([hashtable]$O, [bool]$Interactive, [string]$PubPath = '', [bool]$Batch = $false, [bool]$FromKnownHosts = $false)

    $fromKnown = $FromKnownHosts -or [bool]$O.FromKnownHosts
    Write-Section $(if ($fromKnown) { 'Deploy to known_hosts' } elseif ($Batch) { 'Batch deploy' } else { 'Deploy public key' })

    # Which key? --------------------------------------------------------------
    if (-not $PubPath) {
        if ($O.Key) { $PubPath = Resolve-PubKey $O.Key }
        elseif ($Interactive) {
            $keys = @(Get-KeyInfo)
            if ($keys.Count -eq 0) { throw "No public keys found in $($script:SshDir). Generate one first." }
            if ($keys.Count -eq 1) {
                Write-Info "Using the only key found: $($keys[0].Name)"
                $PubPath = $keys[0].Path
            }
            else {
                Show-KeyList -Keys $keys
                Write-Host ''
                $max = $keys.Count
                $n = [int](Read-Prompt -Label 'Key to deploy (number)' -Default '1' -Validate {
                    param($v)
                    if ($v -notmatch '^\d{1,3}$' -or [int]$v -lt 1 -or [int]$v -gt $max) { "Enter a number between 1 and $max." }
                })
                $PubPath = $keys[$n - 1].Path
            }
        }
        else {
            $default = Join-Path $script:SshDir 'id_ed25519.pub'
            if (Test-Path -LiteralPath $default) { $PubPath = $default }
            else { throw 'No key specified. Use --key <name|path>.' }
        }
    }

    $pubLine = @(Get-Content -LiteralPath $PubPath -ErrorAction Stop | Where-Object { $_.Trim() }) | Select-Object -First 1
    $keyPattern = '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\s+[A-Za-z0-9+/=]+(\s.*)?$'
    if (-not $pubLine -or $pubLine -notmatch $keyPattern) {
        throw "'$PubPath' does not look like a valid OpenSSH public key."
    }
    $pubLine = $pubLine.Trim()
    Write-Info "Key: $PubPath"
    Write-Host ''

    # Needed for the password login and the upload; offers to install the module on first use.
    Initialize-PoshSsh

    # Target type ---------------------------------------------------------------
    $target = 'auto'
    if ($O.Target) { $target = Resolve-Target $O.Target }
    elseif ($Interactive) {
        $target = Select-Option -Title 'Target type' -Default 1 -Options @(
            @{ Value = 'auto';     Text = 'auto';     Note = 'detect the remote OS after login (recommended)' }
            @{ Value = 'linux';    Text = 'linux';    Note = 'OpenSSH server - ~/.ssh/authorized_keys' }
            @{ Value = 'esxi';     Text = 'esxi';     Note = 'VMware ESXi - /etc/ssh/keys-<user>/authorized_keys' }
            @{ Value = 'mikrotik'; Text = 'mikrotik'; Note = 'RouterOS - uploads the key and imports it' }
        )
        Write-Host ''
    }
    if ($target -ne 'auto') { Assert-KeyFitsTarget -Target $target -PubLine $pubLine }   # fail fast; auto re-checks per host

    # Hosts: a single host, a host-list file, or a picker over known_hosts ---------------
    $listFile = $O.HostList
    $server   = $O.Server
    $knownHostsEntries = $null
    if ($fromKnown) {
        # Always shows the picker - there is no non-interactive form of "pick some hosts from a list" yet.
        $knownHostsEntries = Select-KnownHosts
    }
    elseif ($Batch -and -not $listFile) {
        Show-HostListHelp
        $listFile = (Read-Prompt -Label 'Path to the host-list file' -Validate {
            param($v) if (-not (Test-Path -LiteralPath $v.Trim('"') -PathType Leaf)) { "File not found: $v" }
        }).Trim('"')
    }
    elseif (-not $listFile -and -not $server) {
        if (-not $Interactive) { throw 'Missing target. Use --host <ip|name> or --host-list <file>.' }
        $server = Read-Prompt -Label 'IP / hostname' -Validate { param($v) Test-HostName $v }
    }
    elseif ($server) {
        $problem = Test-HostName $server
        if ($problem) { throw $problem }
    }

    $port = [int](Resolve-Value -Given $O.Port -Interactive $Interactive -Label 'SSH port' -Default '22' `
                -Validate { param($v) Test-PortNum $v })

    $defaultUser = ''
    if (($Batch -or $fromKnown) -and -not $O.Username -and ($Interactive -or $fromKnown)) {
        $hint = if ($fromKnown) { '' } else { ' (Enter to skip if every line has user@)' }
        $defaultUser = Read-Prompt -Label "Default username$hint" -AllowEmpty:$(-not $fromKnown) `
                -Validate { param($v) Test-UserName $v }
    }
    elseif ($O.Username -or $Interactive -or -not $listFile) {
        $label = if ($listFile) { 'Username (for hosts without user@)' } else { 'Username' }
        $defaultUser = Resolve-Value -Given $O.Username -Interactive $Interactive -Label $label `
                -Validate { param($v) Test-UserName $v } -MissingMessage 'Missing username. Use --user <name>.'
    }

    $entries = @()
    if ($knownHostsEntries) {
        foreach ($e in $knownHostsEntries) { $entries += [pscustomobject]@{ Server = $e.Server; Port = $e.Port; User = $defaultUser } }
    }
    elseif ($listFile) {
        foreach ($e in @(Read-HostList $listFile)) {
            $u = if ($e.User) { $e.User } else { $defaultUser }
            if (-not $u) { throw "No username for host '$($e.Server)': add user@ in the list or use --user." }
            $entries += [pscustomobject]@{ Server = $e.Server; Port = $(if ($e.Port) { $e.Port } else { $port }); User = $u }
        }
    }
    else { $entries = @([pscustomobject]@{ Server = $server; Port = $port; User = $defaultUser }) }
    $bulk = $entries.Count -gt 1

    # Password (asked once, reused for every host) ---------------------------------------
    if ($O.Password) {
        $secure = $O.Password
        if ($secure.Length -eq 0) { throw 'The password must not be empty.' }
    }
    else { $secure = Read-Secret -Label $(if ($bulk) { "Password (used for all $($entries.Count) hosts)" } else { 'Password' }) }

    # Options that apply to every host ---------------------------------------------------
    $acceptKey = [bool]$O.AcceptHostKey
    $disablePw = [bool]$O.DisablePasswordAuth
    if ($disablePw -and $target -notin 'linux', 'auto') { Write-Warn "-DisablePasswordAuth only applies to Linux targets - ignored for '$target'."; $disablePw = $false }
    $askDisable = ($Interactive -and -not $bulk -and $target -in 'linux', 'auto' -and -not $disablePw)

    Write-Host ''
    if ($acceptKey) { Write-Warn 'Host keys are accepted automatically (-AcceptHostKey). Only use this on networks you trust.' }
    else            { Write-Info 'For a new server you will be asked to confirm its host key fingerprint - answer Y only if it matches.' }

    # Go ---------------------------------------------------------------------------------
    $results = @()
    $sshOptions = ''
    $i = 0
    foreach ($e in $entries) {
        $i++
        $label = "$($e.User)@$($e.Server):$($e.Port)"
        if ($bulk) {
            Write-Host ''
            Write-Host "  [$i/$($entries.Count)] " -NoNewline -ForegroundColor Cyan
            Write-Host $label -ForegroundColor White
        }
        try {
            $r = Install-KeyOnHost -Target $target -Server $e.Server -Port $e.Port -Username $e.User -Secure $secure `
                    -PubPath $PubPath -PubLine $pubLine -AcceptKey $acceptKey -DisablePw $disablePw -AskDisablePw $askDisable -Ask ($Interactive -and -not $bulk)
            $detail = "[$($r.Target)] " + $(switch ($r.Status) { 'present' { 'key was already present' } 'unconfirmed' { 'key import NOT confirmed' } default { 'key installed' } })
            $detail += switch ($r.Login) { 'ok' { ', login verified' } 'legacy' { ', login OK only with legacy algorithms' } 'failed' { ', login test FAILED' } default { '' } }
            $sshOptions = $r.SshOptions
            if ($r.Status -eq 'unconfirmed' -and $r.Login -eq 'failed') {
                throw 'The key was NOT installed: the device did not confirm the import and key login fails. Run with -Verbose and check the key list on the device (RouterOS: /user ssh-keys print).'
            }
            $results += [pscustomobject]@{ Host = $label; Ok = $true; Detail = $detail }
        }
        catch {
            if (-not $bulk) { throw }
            Write-Err $_.Exception.Message
            $results += [pscustomobject]@{ Host = $label; Ok = $false; Detail = $_.Exception.Message }
        }
    }

    if ($bulk) {
        Write-Section 'Summary'
        foreach ($r in $results) {
            if ($r.Ok) { Write-Host "  $($script:G.Ok) " -NoNewline -ForegroundColor Green; Write-Host $r.Host.PadRight(34) -NoNewline -ForegroundColor White; Write-Host $r.Detail -ForegroundColor Green }
            else       { Write-Host "  $($script:G.Err) " -NoNewline -ForegroundColor Red;   Write-Host $r.Host.PadRight(34) -NoNewline -ForegroundColor White; Write-Host $r.Detail -ForegroundColor Red }
        }
        $failed = @($results | Where-Object { -not $_.Ok }).Count
        Write-Host ''
        if ($failed -gt 0) { throw "$failed of $($results.Count) hosts failed." }
        Write-Ok "All $($results.Count) hosts done."
    }
    else {
        $priv    = $PubPath -replace '\.pub$', ''
        $portArg = if ($entries[0].Port -ne 22) { " -p $($entries[0].Port)" } else { '' }
        Write-Host ''
        $optArg = if ($sshOptions) { " $sshOptions" } else { '' }
        Write-Info "Connect with:  ssh$optArg -i `"$priv`"$portArg $($entries[0].User)@$($entries[0].Server)"
    }
}

# ============================================================================
#  Interactive menu
# ============================================================================
function Show-Menu {
    try { Clear-Host } catch { }
    Write-Banner
    Write-Host ''
    $items = @(
        @{ N = '1'; T = 'Generate';         D = 'Create a new SSH key pair' }
        @{ N = '2'; T = 'List';             D = 'Show public keys in your .ssh folder' }
        @{ N = '3'; T = 'Deploy';           D = 'Upload a public key to one server' }
        @{ N = '4'; T = 'Batch deploy';     D = 'Upload a public key to many servers from a list file' }
        @{ N = '5'; T = 'Deploy to known_hosts'; D = 'Pick servers you have already connected to' }
        @{ N = '6'; T = 'Exit';             D = '' }
    )
    $titleWidth = (($items | ForEach-Object { $_.T.Length } | Measure-Object -Maximum).Maximum) + 2
    foreach ($item in $items) { Write-MenuItem $item.N $item.T $item.D -Width $titleWidth }
    Write-Host ''
    Write-Host "  Key folder: $($script:SshDir)" -ForegroundColor DarkGray
    Write-Host ''
}

function Start-Interactive {
    while ($true) {
        Show-Menu
        $choice = Read-Prompt -Label 'Select an option' -Validate {
            param($v) if ($v -notmatch '^[1-6]$') { 'Please enter a number from 1 to 6.' }
        }
        switch ($choice) {
            '1' {
                Invoke-Safely {
                    $newKey = Invoke-Generate -O @{} -Interactive $true
                    if ($newKey) {
                        Write-Host ''
                        if (Read-Confirm 'Deploy this key to a server now?' $false) {
                            Invoke-Deploy -O @{} -Interactive $true -PubPath $newKey
                        }
                    }
                }
                Suspend-Menu
            }
            '2' { Invoke-Safely { Show-KeyList -Keys @(Get-KeyInfo) }; Suspend-Menu }
            '3' { Invoke-Safely { Invoke-Deploy -O @{} -Interactive $true }; Suspend-Menu }
            '4' { Invoke-Safely { Invoke-Deploy -O @{} -Interactive $true -Batch $true }; Suspend-Menu }
            '5' { Invoke-Safely { Invoke-Deploy -O @{} -Interactive $true -FromKnownHosts $true }; Suspend-Menu }
            '6' { Write-Host ''; Write-Info 'Goodbye.'; Write-Host ''; return }
        }
    }
}

# ============================================================================
#  Inline (command-line) mode
# ============================================================================
function Show-Usage {
    Write-Banner
    Write-Host ''
    Write-Host '  Usage' -ForegroundColor White
    Write-Host '    .\SshKeyKit.ps1                                   interactive menu' -ForegroundColor Gray
    Write-Host '    .\SshKeyKit.ps1 -Generate [options]               create a key pair' -ForegroundColor Gray
    Write-Host '    .\SshKeyKit.ps1 -List                             list public keys' -ForegroundColor Gray
    Write-Host '    .\SshKeyKit.ps1 -Deploy --host H --user U [...]   upload a key' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  Options  (-Type and --type styles are both accepted)' -ForegroundColor White
    Write-Host '    --type <ed25519|rsa|ecdsa>     default ed25519' -ForegroundColor Gray
    Write-Host '    --bits | --byte | --length <n> RSA 2048-16384 (4096) | ECDSA 256/384/521 (384)' -ForegroundColor Gray
    Write-Host '    --label <text>                 key comment (default user@computer)' -ForegroundColor Gray
    Write-Host '    --name <file>                  file name in ~\.ssh (default id_<type>)' -ForegroundColor Gray
    Write-Host '    -Passphrase <SecureString>     optional key passphrase (prompted in the menu)' -ForegroundColor Gray
    Write-Host '    --host <ip|name> --port <n>    deploy target (port default 22)' -ForegroundColor Gray
    Write-Host '    --user <name> -Password <SecureString>  deploy credentials (prompted, hidden, if omitted)' -ForegroundColor Gray
    Write-Host '    --key <name|path>              public key to deploy (default id_ed25519)' -ForegroundColor Gray
    Write-Host '    --target <auto|linux|esxi|mikrotik>  server type (default auto = detect the remote OS)' -ForegroundColor Gray
    Write-Host '    --host-list <file>             many hosts: host | host:port | user@host[:port]' -ForegroundColor Gray
    Write-Host '    -FromKnownHosts                pick servers from known_hosts (shows a picker)' -ForegroundColor Gray
    Write-Host '    -AddToAgent                    load the new key into ssh-agent' -ForegroundColor Gray
    Write-Host '    -DisablePasswordAuth           Linux: disable SSH password login after a verified key login' -ForegroundColor Gray
    Write-Host '    -Force  -AcceptHostKey  -Help' -ForegroundColor Gray
    Write-Host '    -Verbose                       show every RouterOS command and answer (for troubleshooting)' -ForegroundColor Gray
    Write-Host ''
}

function Merge-CliArguments {
    param([hashtable]$Options, [string[]]$Tokens)

    $valueOptions = @{
        type = 'Type'; bits = 'Bits'; byte = 'Bits'; bytes = 'Bits'; length = 'Bits'; size = 'Bits'
        label = 'Label'; comment = 'Label'; name = 'Name'
        host = 'Server'; hostname = 'Server'; server = 'Server'; ip = 'Server'
        user = 'Username'; username = 'Username'
        key = 'Key'; port = 'Port'; target = 'Target'
        'host-list' = 'HostList'; hostlist = 'HostList'; hosts = 'HostList'
    }
    $switchOptions = @{
        generate = 'Generate'; list = 'List'; deploy = 'Deploy'; force = 'Force'
        'accept-host-key' = 'AcceptHostKey'; accepthostkey = 'AcceptHostKey'; help = 'Help'
        'add-to-agent' = 'AddToAgent'; addtoagent = 'AddToAgent'
        'disable-password-auth' = 'DisablePasswordAuth'; disablepasswordauth = 'DisablePasswordAuth'
        'from-known-hosts' = 'FromKnownHosts'; fromknownhosts = 'FromKnownHosts'
    }

    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $token = $Tokens[$i]
        if ($token -notmatch '^--?([A-Za-z][A-Za-z0-9-]*)(?:=(.*))?$') {
            throw "Unexpected argument '$token'. Options look like: --type ed25519"
        }
        $optName = $Matches[1].ToLower()
        $inline  = if ($Matches.ContainsKey(2)) { $Matches[2] } else { $null }

        if ($optName -in 'password', 'passphrase') {
            $paramName = if ($optName -eq 'password') { 'Password' } else { 'Passphrase' }
            throw ("Plain-text passwords are not accepted on the command line (they end up in shell history and process lists). " +
                   "Enter it at the prompt, or pass a SecureString:  -$paramName (Read-Host -AsSecureString)")
        }
        if ($switchOptions.ContainsKey($optName)) {
            $Options[$switchOptions[$optName]] = $true
            continue
        }
        if (-not $valueOptions.ContainsKey($optName)) { throw "Unknown option '$token'." }

        if ($null -ne $inline) { $value = $inline }
        else {
            if ($i + 1 -ge $Tokens.Count -or $Tokens[$i + 1] -match '^--[A-Za-z]') { throw "Option '$token' needs a value." }
            $i++
            $value = $Tokens[$i]
        }

        $prop = $valueOptions[$optName]
        switch ($prop) {
            'Bits' {
                if ($value -notmatch '^\d{1,5}$') { throw "Option '--$optName' must be a number (got '$value')." }
                $value = [int]$value
            }
            'Port' {
                if ($value -notmatch '^\d{1,5}$' -or [int]$value -lt 1 -or [int]$value -gt 65535) { throw "Port must be between 1 and 65535 (got '$value')." }
                $value = [int]$value
            }
            'Type' {
                $value = $value.ToLower()
                if ($value -notin 'ed25519', 'rsa', 'ecdsa') { throw "Unsupported type '$value'. Use ed25519, rsa or ecdsa." }
            }
        }
        $Options[$prop] = $value
    }
}

# ============================================================================
#  Entry point
# ============================================================================
$opts = @{
    Generate      = $Generate.IsPresent
    List          = $List.IsPresent
    Deploy        = $Deploy.IsPresent
    Help          = $Help.IsPresent
    Force         = $Force.IsPresent
    AcceptHostKey = $AcceptHostKey.IsPresent
    AddToAgent    = $AddToAgent.IsPresent
    FromKnownHosts = $FromKnownHosts.IsPresent
    DisablePasswordAuth = $DisablePasswordAuth.IsPresent
}
foreach ($n in 'Type', 'Bits', 'Label', 'Name', 'Server', 'Username', 'Password', 'Passphrase', 'Key', 'Port', 'Target', 'HostList') {
    if ($PSBoundParameters.ContainsKey($n)) { $opts[$n] = $PSBoundParameters[$n] }
}

$exitCode = 0
try {
    if ($Rest) { Merge-CliArguments -Options $opts -Tokens $Rest }

    if ($opts.Type) {
        $opts.Type = "$($opts.Type)".ToLower()
        if ($opts.Type -notin 'ed25519', 'rsa', 'ecdsa') { throw "Unsupported type '$($opts.Type)'. Use ed25519, rsa or ecdsa." }
    }
    if ($opts.Target) { $opts.Target = Resolve-Target $opts.Target }
    if ($opts.ContainsKey('Port') -and ($opts.Port -lt 1 -or $opts.Port -gt 65535)) { throw 'Port must be between 1 and 65535.' }

    if ($opts.Help) {
        Show-Usage
    }
    elseif ($opts.Generate -or $opts.List -or $opts.Deploy) {
        $newKey = $null
        if ($opts.Generate) { $newKey = Invoke-Generate -O $opts -Interactive $false }
        if ($opts.Deploy)   { Invoke-Deploy -O $opts -Interactive $false -PubPath $(if ($newKey) { $newKey } else { '' }) }
        if ($opts.List)     { Show-KeyList -Keys @(Get-KeyInfo) }
        Write-Host ''
    }
    else {
        Start-Interactive
    }
}
catch {
    Write-Host ''
    Write-Err $_.Exception.Message
    Write-Host ''
    $exitCode = 1
}
exit $exitCode
