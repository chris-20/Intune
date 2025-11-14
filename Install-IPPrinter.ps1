<#
.SYNOPSIS
   Robuste Installation von IP-Druckern für Microsoft Intune
 
.DESCRIPTION
   Optimiertes PowerShell-Skript für die Bereitstellung von IP-Druckern via Intune.
   Enthält umfassendes Logging, Fehlerbehandlung und Prüfungen für zuverlässige Installation.
   
   Voraussetzungen:
   - Unterordner "Drivers" mit allen Treiberdateien (.inf, .cat, .cab)
   - Ausführung mit SYSTEM-Rechten (Intune Standard)
   
   Intune Installationsbefehl:
   %SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Install-IPPrinter-Enhanced.ps1 -PortIPAddress "192.168.1.10" -PrinterName "Drucker HR" -DriverName "HP Universal Printing PCL 6" -DriverInfFileName "hpcu255u.inf"
   
   Detection Rule (Registry):
   Key:   HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Print\Printers\[PrinterName]
   Value: Name
   Type:  REG_SZ
   
.PARAMETER PortIPAddress
   IP-Adresse des Netzwerkdruckers (z.B. "192.168.1.10")
   
.PARAMETER PrinterName
   Anzeigename des Druckers in Windows (z.B. "Drucker HR")
   
.PARAMETER DriverName
   Exakter Treibername aus der INF-Datei (z.B. "HP Universal Printing PCL 6")
   
.PARAMETER DriverInfFileName
   Name der INF-Datei inklusive Endung (z.B. "hpcu255u.inf")
   
.PARAMETER SharedPrinter
   Optional: Drucker als Netzwerkfreigabe einrichten (Standard: $false)
   
.EXAMPLE
   Install-IPPrinter-Enhanced.ps1 -PortIPAddress "192.168.1.10" -PrinterName "Drucker 1. OG" -DriverName "HP Universal Printing PCL 6" -DriverInfFileName "hpcu255u.inf"
   
.NOTES
  Version:        2.0
  Author:         Enhanced for Intune
  Creation Date:  2025-11-14
  Purpose/Change: Vollständig überarbeitete Version mit verbesserter Stabilität und Intune-Kompatibilität
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true, HelpMessage = "IP-Adresse des Druckers")]
    [ValidatePattern('^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$')]
    [string]$PortIPAddress,

    [Parameter(Mandatory = $true, HelpMessage = "Name des Druckers")]
    [ValidateNotNullOrEmpty()]
    [string]$PrinterName,

    [Parameter(Mandatory = $true, HelpMessage = "Exakter Name des Druckertreibers")]
    [ValidateNotNullOrEmpty()]
    [string]$DriverName,

    [Parameter(Mandatory = $true, HelpMessage = "Name der INF-Datei")]
    [ValidatePattern('\.inf$')]
    [string]$DriverInfFileName,

    [Parameter(Mandatory = $false, HelpMessage = "Drucker als Netzwerkfreigabe einrichten")]
    [bool]$SharedPrinter = $false
)

#############################################
### KONFIGURATION
#############################################

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Logging-Konfiguration
$Global:LogPath = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs"
$Global:LogFile = Join-Path $LogPath "PrinterInstall_$($PrinterName -replace '[^\w\-]', '_').log"

# Retry-Konfiguration
$Script:MaxRetries = 3
$Script:RetryDelaySeconds = 5

#############################################
### LOGGING-FUNKTIONEN
#############################################

function Initialize-Logging {
    try {
        if (-not (Test-Path $Global:LogPath)) {
            New-Item -Path $Global:LogPath -ItemType Directory -Force | Out-Null
        }
        
        # Log-Rotation: Alte Logs über 30 Tage löschen
        Get-ChildItem -Path $Global:LogPath -Filter "PrinterInstall_*.log" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
            
        return $true
    }
    catch {
        Write-Warning "Logging konnte nicht initialisiert werden: $_"
        return $false
    }
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp [$Level] $Message"
    
    try {
        Add-Content -Path $Global:LogFile -Value $logMessage -ErrorAction SilentlyContinue
    }
    catch {
        # Fallback zu Write-Host wenn Logging fehlschlägt
        Write-Host $logMessage
    }
    
    # Zusätzliche Konsolenausgabe für Debugging
    switch ($Level) {
        'ERROR'   { Write-Error $Message -ErrorAction Continue }
        'WARNING' { Write-Warning $Message }
        'SUCCESS' { Write-Host $logMessage -ForegroundColor Green }
        default   { Write-Verbose $logMessage }
    }
}

function Exit-WithError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [int]$ExitCode = 1
    )
    
    Write-Log -Message "FATAL: $Message" -Level 'ERROR'
    Write-Log -Message "Installation fehlgeschlagen mit Exit Code: $ExitCode" -Level 'ERROR'
    exit $ExitCode
}

#############################################
### HILFSFUNKTIONEN
#############################################

function Test-IsAdmin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        
        [Parameter(Mandatory = $true)]
        [string]$ActionName,
        
        [int]$MaxRetries = $Script:MaxRetries,
        [int]$DelaySeconds = $Script:RetryDelaySeconds
    )
    
    $attempt = 0
    $success = $false
    
    while (-not $success -and $attempt -lt $MaxRetries) {
        $attempt++
        
        try {
            Write-Log -Message "$ActionName (Versuch $attempt von $MaxRetries)..." -Level 'INFO'
            & $ScriptBlock
            $success = $true
            Write-Log -Message "$ActionName erfolgreich." -Level 'SUCCESS'
        }
        catch {
            Write-Log -Message "$ActionName fehlgeschlagen: $($_.Exception.Message)" -Level 'WARNING'
            
            if ($attempt -lt $MaxRetries) {
                Write-Log -Message "Warte $DelaySeconds Sekunden vor erneutem Versuch..." -Level 'INFO'
                Start-Sleep -Seconds $DelaySeconds
            }
            else {
                throw
            }
        }
    }
    
    return $success
}

function Test-NetworkConnectivity {
    param([string]$IPAddress)
    
    Write-Log -Message "Prüfe Netzwerkverbindung zu $IPAddress..." -Level 'INFO'
    
    try {
        $ping = Test-Connection -ComputerName $IPAddress -Count 2 -Quiet -ErrorAction Stop
        
        if ($ping) {
            Write-Log -Message "Drucker unter $IPAddress ist erreichbar." -Level 'SUCCESS'
            return $true
        }
        else {
            Write-Log -Message "Drucker unter $IPAddress ist momentan NICHT erreichbar (z.B. Homeoffice)." -Level 'WARNING'
            Write-Log -Message "Installation wird trotzdem fortgesetzt - Drucker wird verfügbar sobald im Netzwerk." -Level 'INFO'
            return $false
        }
    }
    catch {
        Write-Log -Message "Netzwerkprüfung nicht möglich: $($_.Exception.Message)" -Level 'WARNING'
        Write-Log -Message "Installation wird trotzdem fortgesetzt - Drucker wird verfügbar sobald im Netzwerk." -Level 'INFO'
        return $false
    }
}

#############################################
### HAUPT-INSTALLATIONSFUNKTIONEN
#############################################

function Initialize-PrintSpooler {
    Write-Log -Message "Prüfe Print Spooler Dienst..." -Level 'INFO'
    
    try {
        $spooler = Get-Service -Name Spooler -ErrorAction Stop
        
        if ($spooler.Status -ne 'Running') {
            Write-Log -Message "Print Spooler wird gestartet..." -Level 'INFO'
            Start-Service -Name Spooler -ErrorAction Stop
            Start-Sleep -Seconds 3
        }
        
        Write-Log -Message "Print Spooler läuft." -Level 'SUCCESS'
        return $true
    }
    catch {
        Write-Log -Message "Print Spooler Fehler: $($_.Exception.Message)" -Level 'ERROR'
        return $false
    }
}

function Install-PrinterDriver {
    param(
        [string]$DriverPath,
        [string]$DriverName
    )
    
    Write-Log -Message "=== TREIBER-INSTALLATION ===" -Level 'INFO'
    Write-Log -Message "Treiberpfad: $DriverPath" -Level 'INFO'
    Write-Log -Message "Treibername: $DriverName" -Level 'INFO'
    
    # Schritt 1: Treiber mit pnputil stagen
    Write-Log -Message "Starte pnputil zum Stagen des Treibers..." -Level 'INFO'
    
    try {
        $pnputilArgs = @('/add-driver', "`"$DriverPath`"", '/install')
        $pnputilProcess = Start-Process -FilePath 'pnputil.exe' -ArgumentList $pnputilArgs -Wait -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\pnputil_out.txt" -RedirectStandardError "$env:TEMP\pnputil_err.txt"
        
        $pnputilOutput = Get-Content "$env:TEMP\pnputil_out.txt" -Raw -ErrorAction SilentlyContinue
        $pnputilError = Get-Content "$env:TEMP\pnputil_err.txt" -Raw -ErrorAction SilentlyContinue
        
        Write-Log -Message "pnputil Exit Code: $($pnputilProcess.ExitCode)" -Level 'INFO'
        
        if ($pnputilOutput) { Write-Log -Message "pnputil Output: $pnputilOutput" -Level 'INFO' }
        if ($pnputilError) { Write-Log -Message "pnputil Error: $pnputilError" -Level 'WARNING' }
        
        # Kurze Wartezeit nach pnputil
        Start-Sleep -Seconds 3
    }
    catch {
        Write-Log -Message "pnputil Fehler: $($_.Exception.Message)" -Level 'WARNING'
    }
    finally {
        Remove-Item "$env:TEMP\pnputil_out.txt" -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\pnputil_err.txt" -Force -ErrorAction SilentlyContinue
    }
    
    # Schritt 2: Treiber im System prüfen und installieren
    Write-Log -Message "Prüfe ob Treiber im System verfügbar ist..." -Level 'INFO'
    
    $driverCheck = Get-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue
    
    if ($null -eq $driverCheck) {
        Write-Log -Message "Treiber noch nicht installiert - führe Add-PrinterDriver aus..." -Level 'INFO'
        
        Invoke-WithRetry -ActionName "Add-PrinterDriver" -ScriptBlock {
            Add-PrinterDriver -Name $DriverName -ErrorAction Stop
        }
        
        Start-Sleep -Seconds 2
    }
    else {
        Write-Log -Message "Treiber bereits vorhanden." -Level 'INFO'
    }
    
    # Schritt 3: Finale Validierung
    $finalCheck = Get-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue
    
    if ($null -eq $finalCheck) {
        throw "Treiber '$DriverName' konnte nicht installiert werden."
    }
    
    Write-Log -Message "Treiber erfolgreich installiert: $DriverName" -Level 'SUCCESS'
}

function Add-TCPIPPrinterPort {
    param(
        [string]$PortName,
        [string]$IPAddress
    )
    
    Write-Log -Message "=== PORT-KONFIGURATION ===" -Level 'INFO'
    Write-Log -Message "Port-Name: $PortName" -Level 'INFO'
    Write-Log -Message "IP-Adresse: $IPAddress" -Level 'INFO'
    
    # Bestehenden Port entfernen falls vorhanden
    $existingPort = Get-PrinterPort -Name $PortName -ErrorAction SilentlyContinue
    
    if ($existingPort) {
        Write-Log -Message "Port existiert bereits - prüfe Konfiguration..." -Level 'INFO'
        
        if ($existingPort.PrinterHostAddress -ne $IPAddress) {
            Write-Log -Message "Port-IP stimmt nicht überein - Port wird neu erstellt..." -Level 'WARNING'
            
            try {
                Remove-PrinterPort -Name $PortName -ErrorAction Stop
                Write-Log -Message "Alter Port entfernt." -Level 'INFO'
                Start-Sleep -Seconds 2
            }
            catch {
                Write-Log -Message "Port konnte nicht entfernt werden: $($_.Exception.Message)" -Level 'WARNING'
            }
        }
        else {
            Write-Log -Message "Port-Konfiguration ist korrekt." -Level 'SUCCESS'
            return
        }
    }
    
    # Port erstellen
    Write-Log -Message "Erstelle neuen TCP/IP-Port..." -Level 'INFO'
    
    Invoke-WithRetry -ActionName "Add-PrinterPort" -ScriptBlock {
        Add-PrinterPort -Name $PortName -PrinterHostAddress $IPAddress -ErrorAction Stop
    }
    
    # Validierung
    $portCheck = Get-PrinterPort -Name $PortName -ErrorAction SilentlyContinue
    
    if ($null -eq $portCheck) {
        throw "Port '$PortName' konnte nicht erstellt werden."
    }
    
    Write-Log -Message "Port erfolgreich erstellt: $PortName" -Level 'SUCCESS'
}

function Add-NetworkPrinter {
    param(
        [string]$Name,
        [string]$PortName,
        [string]$DriverName,
        [bool]$Shared
    )
    
    Write-Log -Message "=== DRUCKER-INSTALLATION ===" -Level 'INFO'
    Write-Log -Message "Druckername: $Name" -Level 'INFO'
    Write-Log -Message "Port: $PortName" -Level 'INFO'
    Write-Log -Message "Treiber: $DriverName" -Level 'INFO'
    
    # Bestehenden Drucker entfernen
    $existingPrinter = Get-Printer -Name $Name -ErrorAction SilentlyContinue
    
    if ($existingPrinter) {
        Write-Log -Message "Drucker existiert bereits - wird entfernt und neu erstellt..." -Level 'INFO'
        
        try {
            Remove-Printer -Name $Name -ErrorAction Stop
            Write-Log -Message "Alter Drucker entfernt." -Level 'INFO'
            Start-Sleep -Seconds 3
        }
        catch {
            Write-Log -Message "Drucker konnte nicht entfernt werden: $($_.Exception.Message)" -Level 'WARNING'
        }
    }
    
    # Drucker erstellen
    Write-Log -Message "Erstelle Drucker..." -Level 'INFO'
    
    Invoke-WithRetry -ActionName "Add-Printer" -ScriptBlock {
        Add-Printer -Name $Name -PortName $PortName -DriverName $DriverName -ErrorAction Stop
    }
    
    Start-Sleep -Seconds 2
    
    # Drucker-Eigenschaften konfigurieren
    try {
        # Drucker veröffentlichen (wichtig für Sichtbarkeit)
        Set-Printer -Name $Name -Published $true -ErrorAction SilentlyContinue
        
        if ($Shared) {
            Set-Printer -Name $Name -Shared $true -ShareName $Name -ErrorAction Stop
            Write-Log -Message "Drucker als Netzwerkfreigabe konfiguriert." -Level 'INFO'
        }
        
        # Drucker-Attribute setzen (hilft bei Erkennung in Einstellungen)
        Set-Printer -Name $Name -KeepPrintedJobs $false -ErrorAction SilentlyContinue
        
        Write-Log -Message "Drucker-Eigenschaften konfiguriert." -Level 'INFO'
    }
    catch {
        Write-Log -Message "Warnung bei Eigenschaften-Konfiguration: $($_.Exception.Message)" -Level 'WARNING'
    }
    
    # Validierung
    $printerCheck = Get-Printer -Name $Name -ErrorAction SilentlyContinue
    
    if ($null -eq $printerCheck) {
        throw "Drucker '$Name' konnte nicht erstellt werden."
    }
    
    Write-Log -Message "Drucker erfolgreich installiert: $Name" -Level 'SUCCESS'
    
    # Registry-Eintrag für Intune Detection prüfen
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers\$Name"
    if (Test-Path $regPath) {
        Write-Log -Message "Registry-Eintrag für Detection vorhanden: $regPath" -Level 'SUCCESS'
    }
    else {
        Write-Log -Message "WARNUNG: Registry-Eintrag für Detection nicht gefunden!" -Level 'WARNING'
    }
}

function Test-PrinterInstallation {
    param([string]$PrinterName)
    
    Write-Log -Message "=== INSTALLATIONS-VALIDIERUNG ===" -Level 'INFO'
    
    $allChecks = @()
    
    # Check 1: Drucker in Get-Printer
    $printer = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
    $allChecks += [PSCustomObject]@{
        Check = "Get-Printer"
        Status = ($null -ne $printer)
        Details = if ($printer) { "Status: $($printer.PrinterStatus)" } else { "Nicht gefunden" }
    }
    
    # Check 2: Registry-Eintrag
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers\$PrinterName"
    $regExists = Test-Path $regPath
    $allChecks += [PSCustomObject]@{
        Check = "Registry-Eintrag"
        Status = $regExists
        Details = $regPath
    }
    
    # Check 3: WMI-Abfrage
    $wmiPrinter = Get-CimInstance -ClassName Win32_Printer -Filter "Name='$PrinterName'" -ErrorAction SilentlyContinue
    $allChecks += [PSCustomObject]@{
        Check = "WMI Win32_Printer"
        Status = ($null -ne $wmiPrinter)
        Details = if ($wmiPrinter) { "DeviceID: $($wmiPrinter.DeviceID)" } else { "Nicht gefunden" }
    }
    
    # Check 4: Druckertreiber
    if ($printer) {
        $driver = Get-PrinterDriver -Name $printer.DriverName -ErrorAction SilentlyContinue
        $allChecks += [PSCustomObject]@{
            Check = "Druckertreiber"
            Status = ($null -ne $driver)
            Details = if ($driver) { $driver.Name } else { "Nicht gefunden" }
        }
    }
    
    # Ergebnisse loggen
    foreach ($check in $allChecks) {
        $level = if ($check.Status) { 'SUCCESS' } else { 'WARNING' }
        Write-Log -Message "$($check.Check): $($check.Status) - $($check.Details)" -Level $level
    }
    
    $failedChecks = @($allChecks | Where-Object { -not $_.Status })
    
    if ($failedChecks.Count -eq 0) {
        Write-Log -Message "Alle Validierungschecks erfolgreich!" -Level 'SUCCESS'
        return $true
    }
    else {
        Write-Log -Message "$($failedChecks.Count) von $($allChecks.Count) Checks fehlgeschlagen." -Level 'WARNING'
        return $false
    }
}

#############################################
### HAUPTPROGRAMM
#############################################

try {
    # Initialisierung
    Initialize-Logging | Out-Null
    
    Write-Log -Message "============================================================" -Level 'INFO'
    Write-Log -Message "Drucker-Installation gestartet" -Level 'INFO'
    Write-Log -Message "============================================================" -Level 'INFO'
    Write-Log -Message "Parameter:" -Level 'INFO'
    Write-Log -Message "  - IP-Adresse:    $PortIPAddress" -Level 'INFO'
    Write-Log -Message "  - Druckername:   $PrinterName" -Level 'INFO'
    Write-Log -Message "  - Treiber:       $DriverName" -Level 'INFO'
    Write-Log -Message "  - INF-Datei:     $DriverInfFileName" -Level 'INFO'
    Write-Log -Message "  - Freigabe:      $SharedPrinter" -Level 'INFO'
    Write-Log -Message "Systeminfo:" -Level 'INFO'
    Write-Log -Message "  - PowerShell:    $($PSVersionTable.PSVersion)" -Level 'INFO'
    Write-Log -Message "  - Windows:       $([System.Environment]::OSVersion.VersionString)" -Level 'INFO'
    Write-Log -Message "  - Benutzer:      $env:USERNAME" -Level 'INFO'
    Write-Log -Message "  - Computername:  $env:COMPUTERNAME" -Level 'INFO'
    Write-Log -Message "============================================================" -Level 'INFO'
    
    # Admin-Rechte prüfen
    if (-not (Test-IsAdmin)) {
        Exit-WithError -Message "Script muss mit Administratorrechten ausgeführt werden!" -ExitCode 5
    }
    
    # Script-Pfad bestimmen
    if ($PSScriptRoot) {
        $scriptRoot = $PSScriptRoot
    }
    else {
        $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
    }
    
    Write-Log -Message "Script-Verzeichnis: $scriptRoot" -Level 'INFO'
    
    # Treiberpfad validieren
    $driverPath = Join-Path $scriptRoot "Drivers\$DriverInfFileName"
    
    if (-not (Test-Path $driverPath)) {
        Exit-WithError -Message "Treiber-INF nicht gefunden: $driverPath" -ExitCode 2
    }
    
    Write-Log -Message "Treiber-INF gefunden: $driverPath" -Level 'SUCCESS'
    
    # Zusätzliche Treiberdateien prüfen
    $driverDir = Split-Path $driverPath -Parent
    $driverFiles = Get-ChildItem -Path $driverDir -File
    Write-Log -Message "Treiberdateien im Verzeichnis: $($driverFiles.Count)" -Level 'INFO'
    
    # Port-Name definieren
    $portName = "IP_$PortIPAddress"
    Write-Log -Message "Port-Name: $portName" -Level 'INFO'
    
    # Netzwerkverbindung testen (nicht blockierend - nur Information)
    $networkAvailable = Test-NetworkConnectivity -IPAddress $PortIPAddress
    
    if ($networkAvailable) {
        Write-Log -Message "Drucker ist aktuell im Netzwerk erreichbar." -Level 'INFO'
    }
    else {
        Write-Log -Message "Drucker ist aktuell nicht erreichbar - Installation erfolgt trotzdem." -Level 'INFO'
        Write-Log -Message "Der Drucker wird automatisch funktionieren, sobald der Computer im Firmennetzwerk ist." -Level 'INFO'
    }
    
    # Print Spooler initialisieren
    if (-not (Initialize-PrintSpooler)) {
        Exit-WithError -Message "Print Spooler konnte nicht gestartet werden!" -ExitCode 3
    }
    
    # === INSTALLATION ===
    
    # 1. Treiber installieren
    try {
        Install-PrinterDriver -DriverPath $driverPath -DriverName $DriverName
    }
    catch {
        Exit-WithError -Message "Treiber-Installation fehlgeschlagen: $($_.Exception.Message)" -ExitCode 10
    }
    
    # 2. Port erstellen
    try {
        Add-TCPIPPrinterPort -PortName $portName -IPAddress $PortIPAddress
    }
    catch {
        Exit-WithError -Message "Port-Erstellung fehlgeschlagen: $($_.Exception.Message)" -ExitCode 11
    }
    
    # 3. Drucker hinzufügen
    try {
        Add-NetworkPrinter -Name $PrinterName -PortName $portName -DriverName $DriverName -Shared $SharedPrinter
    }
    catch {
        Exit-WithError -Message "Drucker-Installation fehlgeschlagen: $($_.Exception.Message)" -ExitCode 12
    }
    
    # Kurze Stabilisierungszeit
    Write-Log -Message "Warte auf System-Stabilisierung..." -Level 'INFO'
    Start-Sleep -Seconds 5
    
    # === VALIDIERUNG ===
    
    $validationSuccess = Test-PrinterInstallation -PrinterName $PrinterName
    
    if (-not $validationSuccess) {
        Write-Log -Message "Validierung ergab Warnungen - Installation könnte unvollständig sein." -Level 'WARNING'
    }
    
    # Wartezeit für Intune Detection (verkürzt auf 20 Sekunden)
    Write-Log -Message "Warte 20 Sekunden für Intune Detection Script..." -Level 'INFO'
    Start-Sleep -Seconds 20
    
    # === ABSCHLUSS ===
    
    Write-Log -Message "============================================================" -Level 'SUCCESS'
    Write-Log -Message "Installation erfolgreich abgeschlossen!" -Level 'SUCCESS'
    Write-Log -Message "Drucker '$PrinterName' wurde erfolgreich installiert." -Level 'SUCCESS'
    Write-Log -Message "============================================================" -Level 'SUCCESS'
    
    exit 0
}
catch {
    Exit-WithError -Message "Unerwarteter Fehler: $($_.Exception.Message)" -ExitCode 99
}
