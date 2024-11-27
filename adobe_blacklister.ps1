<#
.SYNOPSIS
   Updates the Windows hosts file with the latest Adobe blacklist.

.DESCRIPTION
   Fetches content from a remote URL, validates it, and updates the hosts file. 
   Creates backups and maintains up to 10 recent backups. Provides detailed logging, 
   error handling, and centralized log management.

.PARAMETER URL
   URL to fetch the blacklist content.

.EXAMPLE
   .\Adobe Hosts File Updater.ps1 -Verbose

.NOTES
   Ensure the script runs with administrator privileges.
#>

# Configuration
$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDirectory) {
    $ScriptDirectory = Get-Location
}

$Config = @{
    URL = "https://a.dove.isdumb.one/list.txt"
    HostsPath = "$env:windir\System32\drivers\etc\hosts"
    BackupFolder = Join-Path $ScriptDirectory "Hosts File Backups"
    EventSource = "Adobe Hosts File Updater"
    StartMarker = "# BEGIN - Adobe Hosts File Blacklist"
    EndMarker = "# END - Adobe Hosts File Blacklist"
    BackupRetentionCount = 10
}

$MarkerPattern = "(?s)" + [regex]::Escape($Config.StartMarker) + "(.*?)" + [regex]::Escape($Config.EndMarker)

# Initialize the log buffer
$script:LogBuffer = @()

# Unified logging function
function Write-Log {
    param (
        [string]$Message,
        [string]$Type = "Information" # Default log type
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "$Timestamp - $Type - $Message"
    $script:LogBuffer += "$Timestamp - $Type - $Message"
}

# Function to flush logs to the event log or fallback file
function Flush-LogBuffer {
    param (
        [string]$EventSource,
        [string]$LogFilePath = "$ScriptDirectory\error.log" # Default fallback file
    )

    # Determine the worst log level
    $WorstLevel = $script:LogBuffer | ForEach-Object {
        if ($_ -match " - (Error|Warning|Information) - ") {
            $matches[1]
        }
    } | Sort-Object -Property { switch ($_) { "Error" { 1 } "Warning" { 2 } "Information" { 3 } default { 4 } } } | Select-Object -First 1

    # Set corresponding event ID and entry type
    switch ($WorstLevel) {
        "Error" { $EntryType = [System.Diagnostics.EventLogEntryType]::Error; $EventId = 6667 }
        "Warning" { $EntryType = [System.Diagnostics.EventLogEntryType]::Warning; $EventId = 6668 }
        "Information" { $EntryType = [System.Diagnostics.EventLogEntryType]::Information; $EventId = 6666 }
        default { $EntryType = [System.Diagnostics.EventLogEntryType]::Information; $EventId = 6666 }
    }

    # Format the log entries into a single message
    $FormattedLog = $script:LogBuffer -join "`n"

    try {
        Write-EventLog -LogName Application -Source $EventSource -EntryType $EntryType -EventId $EventId -Message $FormattedLog
    } catch {
        $script:LogBuffer | Out-File -FilePath $LogFilePath -Append -Encoding UTF8
    }
}

# Fetch list content from the URL
function Get-LatestBlacklist {
    try {
        $Response = Invoke-WebRequest -Uri $Config.URL -UseBasicParsing -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($Response.Content)) {
            $ErrorMessage = "Latest Adobe blacklist is empty."
            Write-Log -Message $ErrorMessage -Type "Error"
            throw $ErrorMessage
        }
        return $Response.Content -replace "`n", "`r`n"
    } catch {
        $ErrorMessage = "Failed to fetch latest Adobe blacklist from $($Config.URL) : $($_.Exception.Message)"
        Write-Log -Message $ErrorMessage -Type "Error"
        throw $ErrorMessage
    }
}

# Validate the fetched content
function Validate-LatestBlacklist {
    param ($Content)
    $Lines = $Content -split "`r?`n"
    foreach ($Line in $Lines) {
        if ($Line -notmatch "^(#|0\.0\.0\.0\s|$)") {
            $ErrorMessage = "Invalid line detected in $($Config.URL) : $Line"
            Write-Log -Message $ErrorMessage -Type "Error"
            throw $ErrorMessage
        }
    }
}

# Determine if update is necessary
function Should-Update-Hosts-File {
    param (
        [string]$CurrentHostsFileContent,
        [string]$LatestBlacklist,
        [string]$MarkerPattern
    )
    if ($CurrentHostsFileContent -match $MarkerPattern) {
        $BlacklistInHostsFile = $matches[1]
        if ($LatestBlacklist.Trim() -eq $BlacklistInHostsFile.Trim()) {
            Write-Log -Message "Hosts file already contains latest Adobe blacklist. No changes required..."
            return $false
        }
    } else {
        Write-Log -Message "No Adobe blacklist found in $($Config.HostsPath). Appending latest Adobe blacklist..."
    }
    return $true
}

# Create backup of the hosts file
function Backup-HostsFile {
    try {
        if (-not (Test-Path $Config.BackupFolder)) {
            New-Item -Path $Config.BackupFolder -ItemType Directory | Out-Null
        }
        $Timestamp = Get-Date -Format "yyyyMMddHHmmss"
        $BackupFile = Join-Path $Config.BackupFolder "hosts_$Timestamp.bak"
        Copy-Item -Path $Config.HostsPath -Destination $BackupFile
        Write-Log -Message "Backup of $($Config.HostsPath) created : $BackupFile"

        # Rotate old backups
        $Backups = Get-ChildItem -Path $Config.BackupFolder -Filter "hosts_*.bak" | Sort-Object CreationTime -Descending
        if ($Backups.Count -gt $Config.BackupRetentionCount) {
            $Backups | Select-Object -Skip $Config.BackupRetentionCount | Remove-Item -Force
            Write-Log -Message "Rotated old backups. Retained last $($Config.BackupRetentionCount)."
        }
    } catch {
        $ErrorMessage = "Failed to create or rotate backups: $($_.Exception.Message)"
        Write-Log -Message $ErrorMessage -Type "Error"
        throw $ErrorMessage
    }
}

function Update-HostsFile {
    param ([string]$HostsContent, [string]$LatestBlacklist)

    $TempFile = Join-Path -Path $ScriptDirectory -ChildPath "hosts.tmp"
    try {
        $UpdatedHosts = $HostsContent -replace $MarkerPattern, ""
        $UpdatedHosts = "$($UpdatedHosts.TrimEnd("`r", "`n"))`r`n`r`n$($Config.StartMarker)`r`n$($LatestBlacklist)`r`n$($Config.EndMarker)"
        Set-Content -Path $TempFile -Value $UpdatedHosts -Encoding Ascii -ErrorAction Stop
        Move-Item -Path $TempFile -Destination $Config.HostsPath -Force -ErrorAction Stop
        Write-Log -Message "Hosts file successfully updated with latest Adobe blacklist."
    } catch {
        $ErrorMessage = "Failed to update hosts file with latest Adobe blacklist : $($_.Exception.Message)"
        Write-Log -Message $ErrorMessage -Type "Error"
        if (Test-Path $TempFile) { Remove-Item -Path $TempFile -Force -ErrorAction SilentlyContinue }
        throw $ErrorMessage
    }
}

# Main Script Execution
try {
    if (-not [System.Diagnostics.EventLog]::SourceExists($Config.EventSource)) {
        [System.Diagnostics.EventLog]::CreateEventSource($Config.EventSource, "Application")
    }

    $LatestBlacklist = Get-LatestBlacklist
    Validate-LatestBlacklist -Content $LatestBlacklist

    if (-not (Test-Path $Config.HostsPath)) {
        throw "Hosts file not found at $($Config.HostsPath)"
    }
    $HostsContent = Get-Content -Path $Config.HostsPath -Raw

    if (-not (Should-Update-Hosts-File -CurrentHostsFileContent $HostsContent -LatestBlacklist $LatestBlacklist -MarkerPattern $MarkerPattern)) {
        Flush-LogBuffer -EventSource $Config.EventSource
        Exit 0
    }

    Backup-HostsFile
    Update-HostsFile -HostsContent $HostsContent -LatestBlacklist $LatestBlacklist
    Flush-LogBuffer -EventSource $Config.EventSource
} catch {
    Write-Log -Message "Error: $($_.Exception.Message)" -Type "Error"
    Flush-LogBuffer -EventSource $Config.EventSource
    Exit 1
}
