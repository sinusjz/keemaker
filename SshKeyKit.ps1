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

    Options
        -Generate / -List / -Deploy       what to do (omit all for the menu)
        --type <ed25519|rsa|ecdsa>        default: ed25519
        --bits | --byte | --length <n>    RSA: 2048-16384 (default 4096) | ECDSA: 256/384/521 (default 384)
                                          (ignored for ed25519 - fixed length)
        --label <text>                    key comment          (default: user@computer)
        --name <file name>                file name in ~\.ssh  (default: id_<type>)
        --passphrase <text>               optional key passphrase (prefer the interactive prompt)
        --host <ip|name>  --port <n>      deploy target        (port default: 22)
        --user <name>     --password <pw> deploy credentials    (password is prompted if omitted)
        --key <name|path>                 public key to deploy (default: id_ed25519)
        -Force                            overwrite existing keys / skip confirmations
        -AcceptHostKey                    trust an unknown server host key without asking
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

    [object]$Password,
    [object]$Passphrase,
    [string]$Key,
    [int]$Port,

    [switch]$Force,
    [switch]$AcceptHostKey,

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
$script:Version = '1.0.0'
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
    param([string]$Number, [string]$Title, [string]$Description)
    Write-Host "   [$Number] " -NoNewline -ForegroundColor Cyan
    Write-Host $Title.PadRight(10) -NoNewline -ForegroundColor White
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

function ConvertTo-Secure {
    param($Value)
    if ($Value -is [securestring]) { return $Value }
    return (ConvertTo-SecureString -String "$Value" -AsPlainText -Force)
}

# Runs an executable with full control over quoting (avoids PowerShell's native-argument quirks,
# e.g. empty-string arguments being dropped in Windows PowerShell 5.1).
function Invoke-Native {
    param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @())

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

    $proc.StandardInput.Close()      # never wait for input
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
        $passphrase = ConvertTo-PlainText (ConvertTo-Secure $O.Passphrase)
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
    return $pub
}

# ============================================================================
#  Action: Deploy
# ============================================================================
function Initialize-PoshSsh {
    if (Get-Module -ListAvailable -Name Posh-SSH) {
        Import-Module Posh-SSH -ErrorAction Stop
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
        Import-Module Posh-SSH -ErrorAction Stop
        Write-Ok 'Posh-SSH installed.'
    }
    catch { throw "Could not install Posh-SSH: $(Get-RootMessage $_.Exception)" }
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
    }
    catch [System.Net.Sockets.SocketException] {
        throw "Cannot reach ${Server}:${Port} - $($_.Exception.Message)"
    }
    finally { $client.Close() }
}

function Invoke-Deploy {
    param([hashtable]$O, [bool]$Interactive, [string]$PubPath = '')

    Write-Section 'Deploy public key'

    # Which key? --------------------------------------------------------------
    if (-not $PubPath) {
        if ($O.Key) { $PubPath = Resolve-PubKey $O.Key }
        elseif ($Interactive) {
            $keys = @(Get-KeyInfo)
            if ($keys.Count -eq 0) { throw "No public keys found in $($script:SshDir). Generate one first." }
            Show-KeyList -Keys $keys
            Write-Host ''
            $max = $keys.Count
            $n = [int](Read-Prompt -Label 'Key to deploy (number)' -Default '1' -Validate {
                param($v)
                if ($v -notmatch '^\d{1,3}$' -or [int]$v -lt 1 -or [int]$v -gt $max) { "Enter a number between 1 and $max." }
            })
            $PubPath = $keys[$n - 1].Path
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

    # Target ------------------------------------------------------------------
    $server   = Resolve-Value -Given $O.Server -Interactive $Interactive -Label 'IP / hostname' `
                    -Validate { param($v) Test-HostName $v } -MissingMessage 'Missing target host. Use --host <ip|name>.'
    $port     = [int](Resolve-Value -Given $O.Port -Interactive $Interactive -Label 'SSH port' -Default '22' `
                    -Validate { param($v) Test-PortNum $v })
    $username = Resolve-Value -Given $O.Username -Interactive $Interactive -Label 'Username' `
                    -Validate { param($v) Test-UserName $v } -MissingMessage 'Missing username. Use --user <name>.'

    if ($O.Password) {
        $secure = ConvertTo-Secure $O.Password
        if ($O.Password -isnot [securestring]) {
            Write-Warn 'A plain-text password on the command line ends up in your shell history - prefer the prompt.'
        }
    }
    else { $secure = Read-Secret -Label 'Password' }

    # Pre-flight --------------------------------------------------------------
    Write-Host ''
    Write-Info "Checking ${server}:${port} ..."
    Assert-HostReachable -Server $server -Port $port
    Write-Ok 'Host is reachable.'

    Initialize-PoshSsh

    # Remote command: create ~/.ssh, fix permissions, append the key only if it is not there yet.
    # The key travels base64-encoded so no quoting/escaping problems are possible.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pubLine))
    $script = @'
umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys; if [ -s ~/.ssh/authorized_keys ] && [ -n "$(tail -c1 ~/.ssh/authorized_keys)" ]; then echo >> ~/.ssh/authorized_keys; fi; KEY=$(echo __B64__ | base64 -d); if grep -qxF -- "$KEY" ~/.ssh/authorized_keys; then echo KPT_PRESENT; else echo "$KEY" >> ~/.ssh/authorized_keys && echo KPT_ADDED; fi; command -v restorecon >/dev/null 2>&1 && restorecon -R ~/.ssh >/dev/null 2>&1; true
'@
    $remoteCommand = "sh -c '" + $script.Replace('__B64__', $b64).Trim() + "'"

    $credential = New-Object System.Management.Automation.PSCredential($username, $secure)
    $session = $null
    try {
        Write-Info "Connecting as ${username}@${server} ..."
        $connect = @{
            ComputerName      = $server
            Port              = $port
            Credential        = $credential
            ConnectionTimeout = 15
            ErrorAction       = 'Stop'
        }
        if ($O.AcceptHostKey) { $connect['AcceptKey'] = $true }

        try { $session = New-SSHSession @connect }
        catch {
            $msg = Get-RootMessage $_.Exception
            if     ($msg -match 'Permission denied|Authentication|auth') { throw "Authentication failed for ${username}@${server} - check the username/password and that password login is enabled in sshd_config." }
            elseif ($msg -match 'timed out|timeout')                     { throw "Connection to ${server}:${port} timed out." }
            elseif ($msg -match 'Key exchange|Object reference')         { throw "Key exchange failed - the server's host key was probably not trusted. Answer Y at the fingerprint prompt, or use -AcceptHostKey. (Otherwise client and server share no common algorithms.)" }
            else                                                         { throw "SSH connection failed: $msg" }
        }
        Write-Ok 'Authenticated.'

        Write-Info 'Installing public key...'
        $result = Invoke-SSHCommand -SSHSession $session -Command $remoteCommand -TimeOut 30
        $output = ($result.Output -join "`n")
        if ($output -notmatch 'KPT_(ADDED|PRESENT)') {
            $stderr = (@($result.Error) -join ' ').Trim()
            throw "Remote command failed (exit $($result.ExitStatus)). $stderr"
        }
        if ($output -match 'KPT_PRESENT') { Write-Ok 'Key was already authorized on the server - nothing changed.' }
        else                              { Write-Ok "Key installed in ~/.ssh/authorized_keys for ${username}@${server}." }
    }
    finally {
        if ($session) { $null = Remove-SSHSession -SSHSession $session -ErrorAction SilentlyContinue }
    }

    # Verify with the native ssh client (skipped for passphrase-protected keys) ----
    $priv   = $PubPath -replace '\.pub$', ''
    $ssh    = Get-Tool 'ssh'
    $keygen = Get-Tool 'ssh-keygen'
    if ($ssh -and $keygen -and (Test-Path -LiteralPath $priv)) {
        $probe = Invoke-Native -File $keygen -Arguments @('-y', '-P', '', '-f', $priv)
        if ($probe.ExitCode -ne 0) {
            Write-Info 'Private key has a passphrase - automatic login test skipped.'
        }
        else {
            Write-Info 'Testing key-based login...'
            $t = Invoke-Native -File $ssh -Arguments @(
                '-o', 'BatchMode=yes', '-o', 'PasswordAuthentication=no', '-o', 'IdentitiesOnly=yes',
                '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=10',
                '-p', "$port", '-i', $priv, "$username@$server", 'echo KPT_OK')
            if ($t.ExitCode -eq 0 -and $t.StdOut -match 'KPT_OK') { Write-Ok 'Key-based login works.' }
            else {
                $why = if ($t.StdErr) { ($t.StdErr -split "\r?\n")[-1] } else { "exit code $($t.ExitCode)" }
                Write-Warn "Key installed, but the login test failed: $why"
                Write-Info 'Check PubkeyAuthentication in sshd_config, SELinux contexts and home-directory permissions.'
            }
        }
    }

    Write-Host ''
    $portArg = if ($port -ne 22) { " -p $port" } else { '' }
    Write-Info "Connect with:  ssh -i `"$priv`"$portArg ${username}@${server}"
}

# ============================================================================
#  Interactive menu
# ============================================================================
function Show-Menu {
    try { Clear-Host } catch { }
    Write-Banner
    Write-Host ''
    Write-MenuItem '1' 'Generate' 'Create a new SSH key pair'
    Write-MenuItem '2' 'List'     'Show public keys in your .ssh folder'
    Write-MenuItem '3' 'Deploy'   "Upload a public key to a Linux host"
    Write-MenuItem '4' 'Exit'     ''
    Write-Host ''
    Write-Host "  Key folder: $($script:SshDir)" -ForegroundColor DarkGray
    Write-Host ''
}

function Start-Interactive {
    while ($true) {
        Show-Menu
        $choice = Read-Prompt -Label 'Select an option' -Validate {
            param($v) if ($v -notmatch '^[1-4]$') { 'Please enter 1, 2, 3 or 4.' }
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
            '4' { Write-Host ''; Write-Info 'Goodbye.'; Write-Host ''; return }
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
    Write-Host '    --passphrase <text>            optional (prefer the interactive prompt)' -ForegroundColor Gray
    Write-Host '    --host <ip|name> --port <n>    deploy target (port default 22)' -ForegroundColor Gray
    Write-Host '    --user <name> --password <pw>  deploy credentials (password prompted if omitted)' -ForegroundColor Gray
    Write-Host '    --key <name|path>              public key to deploy (default id_ed25519)' -ForegroundColor Gray
    Write-Host '    -Force  -AcceptHostKey  -Help' -ForegroundColor Gray
    Write-Host ''
}

function Merge-CliArguments {
    param([hashtable]$Options, [string[]]$Tokens)

    $valueOptions = @{
        type = 'Type'; bits = 'Bits'; byte = 'Bits'; bytes = 'Bits'; length = 'Bits'; size = 'Bits'
        label = 'Label'; comment = 'Label'; name = 'Name'
        host = 'Server'; hostname = 'Server'; server = 'Server'; ip = 'Server'
        user = 'Username'; username = 'Username'; password = 'Password'; passphrase = 'Passphrase'
        key = 'Key'; port = 'Port'
    }
    $switchOptions = @{
        generate = 'Generate'; list = 'List'; deploy = 'Deploy'; force = 'Force'
        'accept-host-key' = 'AcceptHostKey'; accepthostkey = 'AcceptHostKey'; help = 'Help'
    }

    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $token = $Tokens[$i]
        if ($token -notmatch '^--?([A-Za-z][A-Za-z0-9-]*)(?:=(.*))?$') {
            throw "Unexpected argument '$token'. Options look like: --type ed25519"
        }
        $optName = $Matches[1].ToLower()
        $inline  = if ($Matches.ContainsKey(2)) { $Matches[2] } else { $null }

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
}
foreach ($n in 'Type', 'Bits', 'Label', 'Name', 'Server', 'Username', 'Password', 'Passphrase', 'Key', 'Port') {
    if ($PSBoundParameters.ContainsKey($n)) { $opts[$n] = $PSBoundParameters[$n] }
}

$exitCode = 0
try {
    if ($Rest) { Merge-CliArguments -Options $opts -Tokens $Rest }

    if ($opts.Type) {
        $opts.Type = "$($opts.Type)".ToLower()
        if ($opts.Type -notin 'ed25519', 'rsa', 'ecdsa') { throw "Unsupported type '$($opts.Type)'. Use ed25519, rsa or ecdsa." }
    }
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
