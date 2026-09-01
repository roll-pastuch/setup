#requires -version 5.1

<#
.SYNOPSIS
    Prepares a Windows computer for working with the R&P app template.

.DESCRIPTION
    Installs and configures WSL 2 for Docker Desktop, Git for Windows,
    Visual Studio Code, Dev Containers, and a shared Git SSH agent.
    Existing installations are detected and skipped. New installations use the
    latest versions available from WSL or WinGet.

    The script is intended to be run from a Gist like this:

        irm https://raw.githubusercontent.com/roll-pastuch/setup/refs/heads/main/setup.ps1 | iex

    At startup, the script asks for the Git email address and derives the Git
    user name from it. If the current PowerShell is not elevated, Windows then
    displays one UAC prompt. The script never restarts the computer automatically.
#>

$setup = {
    param(
        [string] $ResultPath,
        [string] $GitEmail,
        [string] $GitName
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = "Stop"
    $ProgressPreference = "SilentlyContinue"

    $script:RestartRequired = $false
    $script:Winget = $null
    $summary = [System.Collections.Generic.List[string]]::new()

    # WinGet-Rueckgabewerte, die keinen Fehler darstellen.
    $script:WinGetSuccessCodes = @(
        0,
        1641,        # MSI: Installer hat den Neustart eingeleitet
        3010,        # MSI: Neustart erforderlich, Installation aber erfolgreich
        -1978335189  # 0x8A15002B: kein passendes Update (bereits aktuell)
    )
    $script:WinGetRestartCodes = @(1641, 3010)

    function Write-Step {
        param([string] $Message)

        Write-Host "`n==> $Message" -ForegroundColor Cyan
    }

    function Update-SessionPath {
        $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $env:Path = "$machinePath;$userPath"
    }

    function Invoke-Native {
        <#
            Ruft ein externes Programm auf, ohne dass Ausgaben auf stderr wegen
            $ErrorActionPreference = "Stop" zum Abbruch fuehren. Liefert Exitcode
            und zusammengefuehrte Ausgabe zurueck; UTF-16-Nullbytes (z. B. von
            wsl.exe) werden entfernt.
        #>
        param(
            [Parameter(Mandatory = $true)]
            [string] $FilePath,
            [string[]] $Arguments = @(),
            [switch] $Show
        )

        # Systemwerkzeuge wie wsl.exe liegen in System32, das nicht in jeder
        # Sitzung im Pfad steht.
        $resolved = $null
        $command = Get-Command $FilePath -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $command) {
            $resolved = $command.Source
        }
        elseif ([IO.Path]::IsPathRooted($FilePath) -and (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
            $resolved = $FilePath
        }
        else {
            $systemPath = Join-Path $env:WINDIR "System32\$FilePath"
            if (Test-Path -LiteralPath $systemPath -PathType Leaf) {
                $resolved = $systemPath
            }
        }
        if (-not $resolved) {
            throw "Das Programm '$FilePath' wurde nicht gefunden."
        }

        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = 0
        try {
            $lines = & $resolved @Arguments 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { "$_" }
            }
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }

        $text = (($lines -join "`n") -replace "`0", "")
        if ($Show -and $text.Trim()) {
            Write-Host $text
        }

        return [pscustomobject]@{
            ExitCode = $exitCode
            Output   = $text
        }
    }

    function Resolve-Executable {
        param(
            [string] $Command,
            [string[]] $CandidatePaths = @()
        )

        $found = Get-Command $Command -ErrorAction SilentlyContinue
        if ($null -ne $found) {
            return $found.Source
        }

        foreach ($candidate in $CandidatePaths) {
            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                return $candidate
            }
        }

        return $null
    }

    function Initialize-WinGet {
        Write-Step "Pruefe Windows Package Manager (WinGet)"

        $wingetPath = Resolve-Executable -Command "winget.exe" -CandidatePaths @(
            (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe")
        )

        if (-not $wingetPath) {
            try {
                Add-AppxPackage `
                    -RegisterByFamilyName `
                    -MainPackage "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" `
                    -ErrorAction Stop
            }
            catch {
                Write-Host "WinGet ist nicht registriert; repariere die Installation ..."
                [Net.ServicePointManager]::SecurityProtocol = `
                    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                Install-PackageProvider `
                    -Name NuGet `
                    -Force `
                    -Scope CurrentUser `
                    -Confirm:$false | Out-Null
                Install-Module `
                    -Name Microsoft.WinGet.Client `
                    -Repository PSGallery `
                    -Scope CurrentUser `
                    -Force `
                    -AllowClobber `
                    -Confirm:$false
                Import-Module Microsoft.WinGet.Client -Force
                Repair-WinGetPackageManager -Force -Latest | Out-Null
            }

            Update-SessionPath
            $wingetPath = Resolve-Executable -Command "winget.exe" -CandidatePaths @(
                (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe")
            )
        }

        if (-not $wingetPath) {
            throw "WinGet konnte nicht installiert oder gefunden werden."
        }

        $script:Winget = $wingetPath

        # Eine fehlgeschlagene Quellenaktualisierung ist meist ein Netzwerkproblem
        # und darf das Setup nicht abbrechen.
        $result = Invoke-Native -FilePath $script:Winget -Arguments @(
            "source", "update",
            "--disable-interactivity"
        ) -Show
        if ($result.ExitCode -ne 0) {
            Write-Host "Hinweis: Die WinGet-Paketquellen konnten nicht aktualisiert werden (Code $($result.ExitCode))." `
                -ForegroundColor Yellow
        }
    }

    function Test-WinGetPackage {
        param([string] $Id)

        # Ohne "--source winget", damit auch Pakete erkannt werden, die nicht
        # ueber WinGet installiert wurden (z. B. Docker Desktop von docker.com).
        $result = Invoke-Native -FilePath $script:Winget -Arguments @(
            "list",
            "--id", $Id,
            "--exact",
            "--accept-source-agreements",
            "--disable-interactivity"
        )

        return ($result.ExitCode -eq 0) -and ($result.Output -match [regex]::Escape($Id))
    }

    function Install-WinGetPackage {
        param(
            [string] $Name,
            [string] $Id,
            [string] $Command,
            [string[]] $CandidatePaths = @(),
            [ValidateSet("user", "machine")]
            [string] $Scope,
            [string] $Override = ""
        )

        Write-Step "Pruefe $Name"

        if ((Resolve-Executable -Command $Command -CandidatePaths $CandidatePaths) -or
            (Test-WinGetPackage -Id $Id)) {
            Write-Host "$Name ist bereits installiert; ueberspringe Installation."
            $summary.Add("[OK] $Name war bereits installiert.")
            return
        }

        Write-Host "Installiere die aktuelle Version von $Name ..."
        $arguments = @(
            "install",
            "--id", $Id,
            "--exact",
            "--source", "winget",
            "--accept-package-agreements",
            "--accept-source-agreements",
            "--disable-interactivity",
            "--no-upgrade"
        )

        if ($Override) {
            # "--override" ersetzt die Installer-Argumente vollstaendig und darf
            # von WinGet nicht mit "--silent" kombiniert werden.
            $arguments += @("--override", $Override)
        }
        else {
            $arguments += "--silent"
        }
        if ($Scope) {
            $arguments += @("--scope", $Scope)
        }

        $result = Invoke-Native -FilePath $script:Winget -Arguments $arguments -Show
        if ($result.ExitCode -notin $script:WinGetSuccessCodes) {
            throw "Installation von $Name fehlgeschlagen (WinGet-Code $($result.ExitCode))."
        }
        if ($result.ExitCode -in $script:WinGetRestartCodes) {
            $script:RestartRequired = $true
        }

        Update-SessionPath
        $summary.Add("[OK] $Name wurde installiert.")
    }

    function Get-WslFeatureState {
        $names = @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")
        $states = foreach ($name in $names) {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction SilentlyContinue
            if ($null -eq $feature) { "Missing" } else { $feature.State.ToString() }
        }

        return @($states)
    }

    function Enable-WslFeatures {
        Write-Host "Aktiviere die fuer WSL 2 erforderlichen Windows-Komponenten ..."
        foreach ($name in @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")) {
            try {
                Enable-WindowsOptionalFeature `
                    -Online `
                    -FeatureName $name `
                    -All `
                    -NoRestart `
                    -ErrorAction Stop | Out-Null
            }
            catch {
                throw "Die Windows-Komponente '$name' konnte nicht aktiviert werden: $($_.Exception.Message)"
            }
        }
    }
    function Get-WslVersion {
        $result = Invoke-Native -FilePath "wsl.exe" -Arguments @("--version")
        if ($result.ExitCode -ne 0) {
            return $null
        }

        $match = [regex]::Match($result.Output, "\d+(?:\.\d+){2,3}")
        if (-not $match.Success) {
            return $null
        }

        return [version] $match.Value
    }
    function Initialize-Wsl {
        Write-Step "Pruefe WSL 2 fuer Docker Desktop"

        $featureStates = Get-WslFeatureState
        $featuresEnabled = @($featureStates | Where-Object { $_ -ne "Enabled" }).Count -eq 0
        if (-not $featuresEnabled) {
            Enable-WslFeatures
            $script:RestartRequired = $true
            $summary.Add("[OK] Die Windows-Komponenten fuer WSL 2 wurden aktiviert.")
            return
        }

        $wslVersion = Get-WslVersion
        if (($null -eq $wslVersion) -or ($wslVersion -lt [version] "2.1.5")) {
            Write-Host "Aktualisiere WSL auf eine von Docker unterstuetzte Version ..."
            $update = Invoke-Native -FilePath "wsl.exe" -Arguments @("--update", "--web-download") -Show
            if ($update.ExitCode -ne 0) {
                throw "WSL konnte nicht aktualisiert werden (Code $($update.ExitCode))."
            }
        }

        $setVersion = Invoke-Native -FilePath "wsl.exe" -Arguments @("--set-default-version", "2") -Show
        if ($setVersion.ExitCode -ne 0) {
            throw "WSL 2 konnte nicht als Standard gesetzt werden (Code $($setVersion.ExitCode))."
        }

        $summary.Add("[OK] WSL 2 ist fuer den Docker-Desktop-Backend vorbereitet.")
    }

    function Add-DockerUser {
        # Docker Desktop kann nur von Mitgliedern der Gruppe "docker-users"
        # gestartet werden.
        try {
            $group = Get-LocalGroup -Name "docker-users" -ErrorAction Stop
        }
        catch {
            return
        }

        $account = "$env:USERDOMAIN\$env:USERNAME"
        try {
            $members = @(Get-LocalGroupMember -Group $group -ErrorAction Stop)
        }
        catch {
            $members = @()
        }

        if (@($members | Where-Object { $_.Name -ieq $account }).Count -gt 0) {
            return
        }

        try {
            Add-LocalGroupMember -Group $group -Member $account -ErrorAction Stop
            $summary.Add("[OK] $account wurde der Gruppe docker-users hinzugefuegt.")
        }
        catch {
            Write-Host "Hinweis: $account konnte nicht zur Gruppe docker-users hinzugefuegt werden." `
                -ForegroundColor Yellow
        }
    }

    function Get-GitToolPath {
        param([string] $RelativePath)

        $git = Resolve-Executable -Command "git.exe" -CandidatePaths @(
            (Join-Path $env:ProgramFiles "Git\cmd\git.exe"),
            (Join-Path $env:LOCALAPPDATA "Programs\Git\cmd\git.exe")
        )
        if (-not $git) {
            throw "Git wurde installiert, aber git.exe wurde nicht gefunden."
        }

        $resolvedRoot = Split-Path (Split-Path $git -Parent) -Parent
        $candidateRoots = @(
            $resolvedRoot,
            (Join-Path $env:ProgramFiles "Git"),
            (Join-Path $env:LOCALAPPDATA "Programs\Git")
        )
        foreach ($gitRoot in $candidateRoots) {
            $tool = Join-Path $gitRoot $RelativePath
            if (Test-Path -LiteralPath $tool -PathType Leaf) {
                return $tool
            }
        }

        throw "Das Git-Werkzeug '$RelativePath' wurde nicht gefunden."
    }

    function ConvertTo-GitPosixPath {
        param([string] $Path)

        $root = [IO.Path]::GetPathRoot($Path)
        if ($root -notmatch "^[A-Za-z]:\\$") {
            throw "Der Pfad '$Path' liegt nicht auf einem lokalen Windows-Laufwerk."
        }

        $drive = $root.Substring(0, 1).ToLowerInvariant()
        return "/$drive/" + $Path.Substring($root.Length).Replace("\", "/")
    }

    function Initialize-Git {
        $git = Resolve-Executable -Command "git.exe" -CandidatePaths @(
            (Join-Path $env:ProgramFiles "Git\cmd\git.exe"),
            (Join-Path $env:LOCALAPPDATA "Programs\Git\cmd\git.exe")
        )
        if (-not $git) {
            throw "Git wurde installiert, aber git.exe wurde nicht gefunden."
        }

        $settings = @(
            @("core.autocrlf", "input"),
            @("pull.rebase", "true"),
            @("pull.ff", "true"),
            @("ssh.variant", "ssh"),
            @("user.email", $GitEmail),
            @("user.name", $GitName)
        )
        foreach ($setting in $settings) {
            $result = Invoke-Native -FilePath $git -Arguments @(
                "config", "--global", $setting[0], $setting[1]
            )
            if ($result.ExitCode -ne 0) {
                throw "Git $($setting[0]) konnte nicht konfiguriert werden: $($result.Output)"
            }
        }
        $pullRebase = Invoke-Native -FilePath $git -Arguments @(
            "config", "--global", "--get", "pull.rebase"
        )
        $pullFastForward = Invoke-Native -FilePath $git -Arguments @(
            "config", "--global", "--get", "pull.ff"
        )
        if (($pullRebase.ExitCode -ne 0) -or ($pullRebase.Output.Trim() -ne "true") -or
            ($pullFastForward.ExitCode -ne 0) -or ($pullFastForward.Output.Trim() -ne "true")) {
            throw "Die Standardstrategie fuer git pull konnte nicht auf Rebase gesetzt werden."
        }
        $summary.Add("[OK] Git verwendet Linux-Zeilenenden (core.autocrlf=input).")
        $summary.Add("[OK] Git pull verwendet standardmaessig Rebase.")
        $summary.Add("[OK] Git-Benutzer: $GitName <$GitEmail>")
    }

    function Initialize-VsCodeExtension {
        Write-Step "Pruefe VS Code Dev Containers"

        $code = Resolve-Executable -Command "code.cmd" -CandidatePaths @(
            (Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\bin\code.cmd"),
            (Join-Path $env:ProgramFiles "Microsoft VS Code\bin\code.cmd")
        )
        if (-not $code) {
            throw "VS Code wurde installiert, aber code.cmd wurde nicht gefunden."
        }

        $extensionId = "ms-vscode-remote.remote-containers"
        $installed = (Invoke-Native -FilePath $code -Arguments @("--list-extensions")).Output
        if ($installed -match "(?im)^\s*$([regex]::Escape($extensionId))\s*$") {
            Write-Host "Dev Containers ist bereits installiert; ueberspringe Installation."
            $summary.Add("[OK] VS Code Dev Containers war bereits installiert.")
            return
        }

        $result = Invoke-Native -FilePath $code -Arguments @("--install-extension", $extensionId, "--force") -Show
        if ($result.ExitCode -ne 0) {
            throw "Die VS Code Dev Containers-Erweiterung konnte nicht installiert werden (Code $($result.ExitCode))."
        }
        $summary.Add("[OK] VS Code Dev Containers wurde installiert.")
    }

    function Get-UnusedKeyBase {
        param([string] $Directory)

        $index = 0
        do {
            $index++
            $keyBase = Join-Path $Directory "id_ed25519_github_$index"
        } while ((Test-Path -LiteralPath $keyBase) -or (Test-Path -LiteralPath "$keyBase.pub"))

        return $keyBase
    }

    function Initialize-SshKey {
        Write-Step "Pruefe GitHub SSH-Key"

        $sshKeygen = Resolve-Executable -Command "ssh-keygen.exe" -CandidatePaths @(
            (Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"),
            (Join-Path $env:ProgramFiles "Git\usr\bin\ssh-keygen.exe")
        )
        if (-not $sshKeygen) {
            throw "ssh-keygen.exe wurde nicht gefunden."
        }

        $sshDirectory = Join-Path $env:USERPROFILE ".ssh"
        if (-not (Test-Path -LiteralPath $sshDirectory)) {
            New-Item -ItemType Directory -Path $sshDirectory | Out-Null
        }

        $keyBase = Join-Path $sshDirectory "id_ed25519"
        $publicKeyPath = "$keyBase.pub"

        # PowerShell 5.1 verwirft leere Argumente ("") beim Aufruf externer
        # Programme. '""' wird dagegen als leere Zeichenkette uebergeben - sonst
        # wuerde ssh-keygen das jeweils naechste Argument als Passphrase lesen.
        $emptyPassphrase = '""'

        if (Test-Path -LiteralPath $keyBase) {
            # Nur ein passwortloser Key kann unbeaufsichtigt weiterverwendet werden.
            $derived = Invoke-Native -FilePath $sshKeygen -Arguments @("-y", "-P", $emptyPassphrase, "-f", $keyBase)
            if (($derived.ExitCode -eq 0) -and $derived.Output.Trim()) {
                if (-not (Test-Path -LiteralPath $publicKeyPath)) {
                    $derived.Output.Trim() | Set-Content -LiteralPath $publicKeyPath -Encoding ascii
                }
            }
            else {
                $keyBase = Get-UnusedKeyBase -Directory $sshDirectory
                $publicKeyPath = "$keyBase.pub"
            }
        }
        elseif (Test-Path -LiteralPath $publicKeyPath) {
            $keyBase = Get-UnusedKeyBase -Directory $sshDirectory
            $publicKeyPath = "$keyBase.pub"
        }

        if (-not (Test-Path -LiteralPath $keyBase)) {
            $result = Invoke-Native -FilePath $sshKeygen -Arguments @(
                "-t", "ed25519",
                "-N", $emptyPassphrase,
                "-C", "$env:USERNAME@$env:COMPUTERNAME",
                "-f", $keyBase
            ) -Show
            if ($result.ExitCode -ne 0) {
                throw "Der SSH-Key konnte nicht erstellt werden (Code $($result.ExitCode))."
            }
            $summary.Add("[OK] Ein neuer passwortloser GitHub SSH-Key wurde erstellt: $keyBase")
        }
        else {
            Write-Host "SSH-Key ist bereits vorhanden; ueberspringe Erstellung."
            $summary.Add("[OK] Ein vorhandener SSH-Key wird verwendet: $keyBase")
        }

        if (-not (Test-Path -LiteralPath $publicKeyPath)) {
            throw "Der oeffentliche SSH-Key wurde nicht gefunden: $publicKeyPath"
        }

        $publicKey = (Get-Content -LiteralPath $publicKeyPath -Raw).Trim()

        $summary.Add("")
        $summary.Add("Oeffentlicher SSH-Key:")
        $summary.Add($publicKey)
        $summary.Add("Bei GitHub hinterlegen: https://github.com/settings/ssh/new")

        return $keyBase
    }

    function Initialize-SshAgent {
        param([string] $KeyPath)

        Write-Step "Konfiguriere Git SSH-Agent fuer Dev Containers"

        $git = Resolve-Executable -Command "git.exe" -CandidatePaths @(
            (Join-Path $env:ProgramFiles "Git\cmd\git.exe"),
            (Join-Path $env:LOCALAPPDATA "Programs\Git\cmd\git.exe")
        )
        if (-not $git) {
            throw "Git wurde installiert, aber git.exe wurde nicht gefunden."
        }
        $gitSsh = Get-GitToolPath -RelativePath "usr\bin\ssh.exe"
        $sshAgent = Get-GitToolPath -RelativePath "usr\bin\ssh-agent.exe"
        $sshAdd = Get-GitToolPath -RelativePath "usr\bin\ssh-add.exe"
        $agentDirectory = Join-Path $env:LOCALAPPDATA "ssh-agent"
        $agentSocket = Join-Path $agentDirectory "git-ssh-agent.sock"
        $bridge = Join-Path $agentDirectory "ssh-agent-bridge-noconsole.exe"
        $startupScript = Join-Path $agentDirectory "start-git-ssh-agent.ps1"

        if (-not (Test-Path -LiteralPath $agentDirectory)) {
            New-Item -ItemType Directory -Path $agentDirectory -Force | Out-Null
        }

        # Die Bridge wird auf eine feste Version und Pruefsumme fixiert. Sie
        # stellt den MSYS-Agent von Git Bash ueber die Windows-OpenSSH-Pipe bereit.
        $bridgeUrl = "https://github.com/amurzeau/ssh-agent-bridge/releases/download/v1.1/ssh-agent-bridge-noconsole.exe"
        $bridgeHash = "54394689E8BA37A6A791A3B68CE630B4989AED585533127E8F9CBD1CFF51CF58"
        $bridgeValid = (Test-Path -LiteralPath $bridge -PathType Leaf) -and
            ((Get-FileHash -LiteralPath $bridge -Algorithm SHA256).Hash -eq $bridgeHash)
        if (-not $bridgeValid) {
            $bridgeDownload = "$bridge.download"
            Remove-Item -LiteralPath $bridgeDownload -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri $bridgeUrl -OutFile $bridgeDownload -UseBasicParsing
            $downloadHash = (Get-FileHash -LiteralPath $bridgeDownload -Algorithm SHA256).Hash
            if ($downloadHash -ne $bridgeHash) {
                Remove-Item -LiteralPath $bridgeDownload -Force -ErrorAction SilentlyContinue
                throw "Die Pruefsumme der SSH-Agent-Bridge ist ungueltig."
            }
            Move-Item -LiteralPath $bridgeDownload -Destination $bridge -Force
        }

        $agentSocketPosix = ConvertTo-GitPosixPath -Path $agentSocket
        $keyPathPosix = ConvertTo-GitPosixPath -Path $KeyPath
        # Git bekommt den MSYS-Socket nur innerhalb seines SSH-Kommandos. Eine
        # globale SSH_AUTH_SOCK-Variable wuerde verhindern, dass VS Code unter
        # Windows die Standard-OpenSSH-Pipe erkennt.
        [Environment]::SetEnvironmentVariable("SSH_AUTH_SOCK", $null, "User")
        $env:SSH_AUTH_SOCK = $agentSocketPosix
        $gitSshCommand = 'env SSH_AUTH_SOCK="{0}" "{1}"' -f
            $agentSocketPosix, $gitSsh.Replace("\", "/")
        $gitSshResult = Invoke-Native -FilePath $git -Arguments @(
            "config", "--global", "core.sshCommand", $gitSshCommand
        )
        if ($gitSshResult.ExitCode -ne 0) {
            throw "Git core.sshCommand konnte nicht auf den Git SSH-Agent gesetzt werden."
        }
        if (-not ("RpEnvironmentChangeNotifier" -as [type])) {
            Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class RpEnvironmentChangeNotifier {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint message,
        UIntPtr wParam,
        string lParam,
        uint flags,
        uint timeout,
        out UIntPtr result
    );
}
"@
        }
        $notificationResult = [UIntPtr]::Zero
        [void] [RpEnvironmentChangeNotifier]::SendMessageTimeout(
            [IntPtr] 0xffff,
            0x1A,
            [UIntPtr]::Zero,
            "Environment",
            0x2,
            5000,
            [ref] $notificationResult
        )

        # Die Windows-OpenSSH-Pipe gehoert der Bridge. Der separate Windows-
        # Agent wuerde sonst denselben Namen belegen und einen zweiten Keystore
        # verwenden.
        $windowsSshAgent = Get-Service -Name "ssh-agent" -ErrorAction SilentlyContinue
        if ($null -ne $windowsSshAgent) {
            if ($windowsSshAgent.Status -ne "Stopped") {
                Stop-Service -Name "ssh-agent" -Force
            }
            Set-Service -Name "ssh-agent" -StartupType Disabled
        }

        $startupTemplate = @'
$ErrorActionPreference = "Continue"
$env:SSH_AUTH_SOCK = '__AGENT_SOCKET_POSIX__'
$sshAgent = '__SSH_AGENT__'
$sshAdd = '__SSH_ADD__'
$keyPath = '__KEY_PATH__'
$agentSocket = '__AGENT_SOCKET__'
$bridge = '__BRIDGE__'

& $sshAdd "-l" *> $null
$agentState = $LASTEXITCODE
if ($agentState -eq 2) {
    Remove-Item -LiteralPath $agentSocket -Force -ErrorAction SilentlyContinue
    & $sshAgent "-a" $env:SSH_AUTH_SOCK *> $null
    Start-Sleep -Milliseconds 500
    & $sshAdd "-l" *> $null
    $agentState = $LASTEXITCODE
}
if ($agentState -in @(0, 1)) {
    # Der Key ist passwortlos; erneutes Hinzufuegen ist idempotent und stellt
    # sicher, dass auch ein spaeter ausgewaehlter Key im Agent liegt.
    & $sshAdd $keyPath *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Der SSH-Key konnte nicht in den Git SSH-Agent geladen werden."
    }
}
else {
    throw "Der Git SSH-Agent konnte nicht gestartet werden."
}

$bridgeProcesses = @(
    Get-Process -Name "ssh-agent-bridge-noconsole" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $bridge }
)
foreach ($bridgeProcess in $bridgeProcesses) {
    Stop-Process -Id $bridgeProcess.Id -Force
}
$bridgeArguments = '--from pipe --to cygwin --pipe "\\.\pipe\openssh-ssh-agent" --cygwin-socket "{0}" --no-gui-error' -f
    $agentSocket.Replace("\", "/")
Start-Process -FilePath $bridge -ArgumentList $bridgeArguments -WindowStyle Hidden
'@
        $startupContent = $startupTemplate
        $startupContent = $startupContent.Replace(
            "__AGENT_SOCKET_POSIX__",
            $agentSocketPosix.Replace("'", "''")
        )
        $startupContent = $startupContent.Replace("__SSH_AGENT__", $sshAgent.Replace("'", "''"))
        $startupContent = $startupContent.Replace("__SSH_ADD__", $sshAdd.Replace("'", "''"))
        $startupContent = $startupContent.Replace("__KEY_PATH__", $keyPathPosix.Replace("'", "''"))
        $startupContent = $startupContent.Replace("__AGENT_SOCKET__", $agentSocket.Replace("'", "''"))
        $startupContent = $startupContent.Replace("__BRIDGE__", $bridge.Replace("'", "''"))
        Set-Content -LiteralPath $startupScript -Value $startupContent -Encoding utf8

        $powershell = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
        $account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $action = New-ScheduledTaskAction `
            -Execute $powershell `
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$startupScript`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $account
        $principal = New-ScheduledTaskPrincipal `
            -UserId $account `
            -LogonType Interactive `
            -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -MultipleInstances IgnoreNew
        Register-ScheduledTask `
            -TaskName "R&P Git SSH Agent" `
            -Action $action `
            -Trigger $trigger `
            -Principal $principal `
            -Settings $settings `
            -Description "Startet den Git-for-Windows SSH-Agent fuer Git und VS Code Dev Containers." `
            -Force | Out-Null
        Start-ScheduledTask -TaskName "R&P Git SSH Agent"

        $agentReady = $false
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            Start-Sleep -Milliseconds 500
            $agentTest = Invoke-Native -FilePath $sshAdd -Arguments @("-l")
            if ($agentTest.ExitCode -eq 0) {
                $agentReady = $true
                break
            }
        }
        if (-not $agentReady) {
            throw "Der Git SSH-Agent wurde gestartet, stellt den SSH-Key aber nicht bereit."
        }

        $windowsSshAdd = Join-Path $env:WINDIR "System32\OpenSSH\ssh-add.exe"
        $pipeReady = $false
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            Start-Sleep -Milliseconds 500
            if (Test-Path -LiteralPath $windowsSshAdd -PathType Leaf) {
                $savedSocket = $env:SSH_AUTH_SOCK
                Remove-Item Env:SSH_AUTH_SOCK -ErrorAction SilentlyContinue
                try {
                    $pipeTest = Invoke-Native -FilePath $windowsSshAdd -Arguments @("-l")
                }
                finally {
                    $env:SSH_AUTH_SOCK = $savedSocket
                }
                if ($pipeTest.ExitCode -eq 0) {
                    $pipeReady = $true
                    break
                }
            }
            else {
                $pipe = [IO.Pipes.NamedPipeClientStream]::new(
                    ".",
                    "openssh-ssh-agent",
                    [IO.Pipes.PipeDirection]::InOut
                )
                try {
                    $pipe.Connect(250)
                    $pipeReady = $pipe.IsConnected
                }
                catch {
                    $pipeReady = $false
                }
                finally {
                    $pipe.Dispose()
                }
                if ($pipeReady) {
                    break
                }
            }
        }
        if (-not $pipeReady) {
            throw "Der Git SSH-Agent ist nicht ueber die Windows-OpenSSH-Pipe erreichbar."
        }

        $summary.Add("[OK] Git verwendet das mitgelieferte OpenSSH und den Git-for-Windows SSH-Agent.")
        $summary.Add("[OK] VS Code Dev Containers erreicht denselben Agent ueber die Windows-OpenSSH-Pipe.")
    }

    try {
        $build = [Environment]::OSVersion.Version.Build
        if ($build -lt 22631) {
            throw "Nicht unterstuetzte Windows-Version (Build $build). Erforderlich ist Windows 11 23H2 oder neuer."
        }

        Write-Host "R&P Windows-Setup" -ForegroundColor Green
        Write-Host "Vorhandene Installationen werden beibehalten und uebersprungen."

        Initialize-Wsl
        Initialize-WinGet

        Install-WinGetPackage `
            -Name "Git for Windows" `
            -Id "Git.Git" `
            -Command "git.exe" `
            -CandidatePaths @(
                (Join-Path $env:ProgramFiles "Git\cmd\git.exe"),
                (Join-Path $env:LOCALAPPDATA "Programs\Git\cmd\git.exe")
            )

        Install-WinGetPackage `
            -Name "Visual Studio Code" `
            -Id "Microsoft.VisualStudioCode" `
            -Command "code.cmd" `
            -Scope "user" `
            -CandidatePaths @(
                (Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\bin\code.cmd"),
                (Join-Path $env:ProgramFiles "Microsoft VS Code\bin\code.cmd")
            )

        Install-WinGetPackage `
            -Name "Docker Desktop" `
            -Id "Docker.DockerDesktop" `
            -Command "Docker Desktop.exe" `
            -CandidatePaths @(
                (Join-Path $env:LOCALAPPDATA "Programs\DockerDesktop\Docker Desktop.exe"),
                (Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe")
            ) `
            -Override "install --quiet --accept-license --backend=wsl-2 --no-windows-containers"

        Add-DockerUser
        Initialize-Git
        Initialize-VsCodeExtension
        $sshKey = Initialize-SshKey
        Initialize-SshAgent -KeyPath $sshKey

        $summary.Insert(0, "R&P Windows-Setup erfolgreich abgeschlossen.")
        if ($script:RestartRequired) {
            $summary.Add("")
            $summary.Add("Starte Windows nach Abschluss einmal neu, bevor Docker Desktop verwendet wird.")
        }
        else {
            $summary.Add("")
            $summary.Add("Kein Windows-Neustart ist fuer WSL erforderlich.")
        }

        $summary | Set-Content -LiteralPath $ResultPath -Encoding utf8
        Write-Host "`n$($summary -join "`n")" -ForegroundColor Green
    }
    catch {
        $errorSummary = @(
            "R&P Windows-Setup ist fehlgeschlagen.",
            "Fehler: $($_.Exception.Message)"
        )
        $errorSummary | Set-Content -LiteralPath $ResultPath -Encoding utf8
        Write-Error $_
        throw
    }
}

function Read-GitIdentity {
    do {
        $email = (Read-Host "Git-E-Mail-Adresse").Trim()
        try {
            $address = [System.Net.Mail.MailAddress]::new($email)
            $valid = $address.Address -eq $email
        }
        catch {
            $valid = $false
        }

        if (-not $valid) {
            Write-Host "Bitte gib eine gueltige E-Mail-Adresse ein." -ForegroundColor Yellow
        }
    } while (-not $valid)

    $nameParts = @(
        $email.Split("@")[0] -split "\." |
            Where-Object { $_ } |
            ForEach-Object {
                $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1).ToLowerInvariant()
            }
    )
    if ($nameParts.Count -eq 0) {
        throw "Aus der E-Mail-Adresse konnte kein Git-Benutzername abgeleitet werden."
    }

    return [pscustomobject]@{
        Email = $email
        Name  = $nameParts -join " "
    }
}

function Wait-ForKeyPress {
    Write-Host "`nDruecke eine beliebige Taste zum Beenden ..." -ForegroundColor Cyan
    try {
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    catch {
        $null = Read-Host "Druecke die Eingabetaste zum Beenden"
    }
}

try {
    $gitIdentity = Read-GitIdentity
    Write-Host "Git-Benutzername: $($gitIdentity.Name)" -ForegroundColor Green

    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $resultFile = Join-Path ([IO.Path]::GetTempPath()) ("rp-windows-setup-{0}.txt" -f [guid]::NewGuid())

    if ($isAdministrator) {
        & $setup -ResultPath $resultFile -GitEmail $gitIdentity.Email -GitName $gitIdentity.Name
    }
    else {
        Write-Host "Fordere einmalig Administratorrechte fuer WSL an ..." -ForegroundColor Yellow

        $escapedResultFile = $resultFile.Replace("'", "''")
        $escapedGitEmail = $gitIdentity.Email.Replace("'", "''")
        $escapedGitName = $gitIdentity.Name.Replace("'", "''")
        $payload = "& {`n$($setup.ToString())`n} -ResultPath '$escapedResultFile' -GitEmail '$escapedGitEmail' -GitName '$escapedGitName'"
        $elevatedScript = Join-Path `
            ([IO.Path]::GetTempPath()) `
            ("rp-windows-setup-elevated-{0}.ps1" -f [guid]::NewGuid())
        $payload | Set-Content -LiteralPath $elevatedScript -Encoding utf8

        $process = $null
        try {
            # Start-Process setzt in PowerShell 5.1 keine Anfuehrungszeichen; der Pfad
            # kann Leerzeichen enthalten (z. B. C:\Users\Max Mustermann\AppData\...).
            $quotedScript = '"' + $elevatedScript + '"'
            try {
                $process = Start-Process `
                    -FilePath "powershell.exe" `
                    -Verb RunAs `
                    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $quotedScript) `
                    -Wait `
                    -PassThru `
                    -ErrorAction Stop
            }
            catch {
                throw "Administratorrechte wurden nicht erteilt. Bestaetige die Abfrage der Benutzerkontensteuerung und starte den Befehl erneut."
            }
        }
        finally {
            Remove-Item -LiteralPath $elevatedScript -Force -ErrorAction SilentlyContinue
        }

        if (Test-Path -LiteralPath $resultFile) {
            Write-Host ""
            Get-Content -LiteralPath $resultFile -Encoding utf8 | ForEach-Object { Write-Host $_ }
        }

        if (($null -eq $process) -or ($process.ExitCode -ne 0)) {
            $exitCode = if ($null -eq $process) { "unbekannt" } else { $process.ExitCode }
            throw "Das erhoehte Windows-Setup ist fehlgeschlagen (Code $exitCode)."
        }
    }

    if (Test-Path -LiteralPath $resultFile) {
        Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
    }
}
finally {
    Wait-ForKeyPress
}
