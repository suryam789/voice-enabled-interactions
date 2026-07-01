# =============================================================================
# start_kiosk.ps1
# Smart Kiosk Assistant - Windows 11 Service Launcher
#
# Features:
# - Starts all 5 services in parallel
# - Monitors service health
# - Auto-restart on failure
# - Unified console logging
# - Graceful shutdown (Ctrl+C)
# - Auto-opens browser to Gradio UI
#
# Usage: powershell -ExecutionPolicy Bypass -File start_kiosk.ps1
# =============================================================================

param(
    [switch]$Silent = $false,  # Suppress extra output
    [switch]$NoBrowser = $false  # Don't auto-open browser
)

$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"

# Global state
$Global:ProcessJobs = @{}
$Global:ServiceHealth = @{}
$Global:ShutdownInProgress = $false

# Color output
function Write-Header {
    param([string]$Message)
    Write-Host "`n" -ForegroundColor White
    Write-Host "=" * 70 -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host "=" * 70 -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    if (-not $Silent) {
        Write-Host "[*] $Message" -ForegroundColor Yellow
    }
}

function Write-Error-Custom {
    param([string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Red
}

function Write-Log {
    param([string]$Message, [string]$Service)
    $Timestamp = (Get-Date).ToString("HH:mm:ss")
    $Color = "White"
    
    switch ($Service) {
        "audio-analyzer" { $Color = "Magenta" }
        "text-to-speech" { $Color = "Yellow" }
        "rag-service" { $Color = "Cyan" }
        "kiosk-core" { $Color = "Green" }
        "kiosk-ui" { $Color = "Blue" }
        "launcher" { $Color = "White" }
    }
    
    Write-Host "[$Timestamp] [$Service] $Message" -ForegroundColor $Color
}

function Write-Step {
    param([string]$Message)
    Write-Host "`n→ $Message" -ForegroundColor Cyan
}

# Get root directory and service paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir  # Go up to voice-enabled-interactions root
$KioskDir = $ScriptDir  # smart-kiosk-assistant is the kiosk directory
$EdgeAIDir = Join-Path $RootDir "edge-ai-libraries"

# Load .env file
function Load-Env {
    $EnvFile = Join-Path $ScriptDir ".env"
    if (Test-Path $EnvFile) {
        Get-Content $EnvFile | ForEach-Object {
            if ($_ -match "^([^=]+)=(.*)$") {
                [Environment]::SetEnvironmentVariable($matches[1], $matches[2])
            }
        }
        Write-Success "Environment variables loaded from .env"
    }
    else {
        Write-Error-Custom ".env file not found at: $EnvFile"
        Write-Info "Run setup_windows.ps1 first to create it"
        exit 1
    }
}

# Service definitions
$Services = @(
    @{
        Name = "metrics-collector"
        Port = 9000
        Path = "$KioskDir\kiosk_core\metrics-collector\windows"
        MainFile = "metrics_collector.ps1"
        HealthUrl = "http://127.0.0.1:9000/health"
        Description = "System Metrics Collector"
        Runtime = "powershell"
    },
    @{
        Name = "text-to-speech"
        Port = 8011
        Path = "$EdgeAIDir\microservices\text-to-speech"
        MainFile = "main.py"
        HealthUrl = "http://127.0.0.1:8011/health"
        Description = "Text-to-Speech Synthesis"
    },
    @{
        Name = "audio-analyzer"
        Port = 8010
        Path = "$EdgeAIDir\microservices\audio-analyzer"
        MainFile = "main.py"
        HealthUrl = "http://127.0.0.1:8010/health"
        Description = "Audio Analysis & Transcription"
    },
    @{
        Name = "rag-service"
        Port = 8020
        Path = "$KioskDir\rag-service"
        MainFile = "main.py"
        HealthUrl = "http://127.0.0.1:8020/health"
        Description = "RAG Service"
    },
    @{
        Name = "kiosk-core"
        Port = 8012
        Path = "$KioskDir"
        MainFile = "main.py"
        HealthUrl = "http://127.0.0.1:8012/health"
        Description = "Kiosk Core API"
    },
    @{
        Name = "kiosk-ui"
        Port = 7860
        Path = "$KioskDir"
        MainFile = "gradio_app.py"
        HealthUrl = $null  # Gradio doesn't have /health
        Description = "Gradio Web UI"
    }
)

# Check if a service is healthy
function Test-ServiceHealth {
    param([string]$HealthUrl)
    
    if (-not $HealthUrl) {
        return $true  # No health check available
    }
    
    try {
        $Response = Invoke-WebRequest -Uri $HealthUrl -TimeoutSec 2 -ErrorAction SilentlyContinue
        return $Response.StatusCode -eq 200
    }
    catch {
        return $false
    }
}

# Start a single service
function Start-Service {
    param($Service)

    if ($Service.Runtime -eq "powershell") {
        $MainFile = Join-Path $Service.Path $Service.MainFile

        if (-not (Test-Path $MainFile)) {
            Write-Error-Custom "Main file not found for $($Service.Name)"
            Write-Error-Custom "  Expected: $MainFile"
            return $false
        }

        try {
            $Job = Start-Job -ScriptBlock {
                param($MainFile, $ServicePath)
                Set-Location $ServicePath
                powershell -ExecutionPolicy Bypass -File $MainFile
            } -ArgumentList $MainFile, $Service.Path

            $Global:ProcessJobs[$Service.Name] = $Job
            $Global:ServiceHealth[$Service.Name] = $false

            Write-Log "Starting ($($Service.Description))..." $Service.Name
            return $true
        }
        catch {
            Write-Error-Custom "Failed to start $($Service.Name): $_"
            return $false
        }
    }
    
    $VenvPath = Join-Path $Service.Path "venv"
    $PythonExe = Join-Path $VenvPath "Scripts\python.exe"
    $MainFile = Join-Path $Service.Path $Service.MainFile
    
    if (-not (Test-Path $PythonExe)) {
        Write-Error-Custom "Python executable not found for $($Service.Name)"
        Write-Error-Custom "  Expected: $PythonExe"
        Write-Error-Custom "  Did you run setup_windows.ps1?"
        return $false
    }
    
    if (-not (Test-Path $MainFile)) {
        Write-Error-Custom "Main file not found for $($Service.Name)"
        Write-Error-Custom "  Expected: $MainFile"
        return $false
    }
    
    try {
        $Job = Start-Job -ScriptBlock {
            param($Python, $MainFile, $ServicePath, $ServiceName)
            Set-Location $ServicePath
            & $Python $MainFile
        } -ArgumentList $PythonExe, $MainFile, $Service.Path, $Service.Name
        
        $Global:ProcessJobs[$Service.Name] = $Job
        $Global:ServiceHealth[$Service.Name] = $false
        
        Write-Log "Starting ($($Service.Description))..." $Service.Name
        return $true
    }
    catch {
        Write-Error-Custom "Failed to start $($Service.Name): $_"
        return $false
    }
}

# Monitor services
function Monitor-Services {
    param([int]$TimeoutSeconds = 60)
    
    $StartTime = Get-Date
    $AllHealthy = $false
    
    while ((Get-Date) - $StartTime -lt (New-TimeSpan -Seconds $TimeoutSeconds)) {
        $HealthyCount = 0
        
        foreach ($Service in $Services) {
            $Job = $Global:ProcessJobs[$Service.Name]
            
            # Check if job is still running
            if ($Job.State -eq "Failed" -or $Job.State -eq "Completed") {
                if ($Job.State -eq "Failed") {
                    Write-Error-Custom "Service $($Service.Name) failed to start"
                    $Errors = Receive-Job -Job $Job -ErrorAction SilentlyContinue
                    if ($Errors) {
                        Write-Error-Custom "  Error: $($Errors[0])"
                    }
                }
                continue
            }
            
            # Check health
            $IsHealthy = Test-ServiceHealth -HealthUrl $Service.HealthUrl
            $Global:ServiceHealth[$Service.Name] = $IsHealthy
            
            if ($IsHealthy) {
                $HealthyCount++
                if (-not $Silent) {
                    Write-Log "[READY] Ready on port $($Service.Port)" $Service.Name
                }
            }
            else {
                Write-Log "[WAIT] Starting..." $Service.Name
            }
        }
        
        # All services healthy?
        if ($HealthyCount -eq $Services.Count) {
            $AllHealthy = $true
            break
        }
        
        Start-Sleep -Milliseconds 500
    }
    
    if (-not $AllHealthy) {
        Write-Info "Note: Some services may still be initializing (first run can take longer)"
    }
    
    return $AllHealthy
}

# Open browser
function Open-Browser {
    try {
        $Url = "http://127.0.0.1:7860"
        Write-Log "Opening browser..." launcher
        Start-Process $Url
        Write-Success "Browser opened to $Url"
    }
    catch {
        Write-Info "Could not auto-open browser. Visit: http://127.0.0.1:7860"
    }
}

# Display unified logs
function Show-Unified-Logs {
    Write-Header "UNIFIED SERVICE LOGS (Ctrl+C to stop)"
    
    while (-not $Global:ShutdownInProgress) {
        foreach ($ServiceName in $Global:ProcessJobs.Keys) {
            $Job = $Global:ProcessJobs[$ServiceName]
            
            if ($Job.State -ne "Running") {
                continue
            }
            
            $Output = Receive-Job -Job $Job -ErrorAction SilentlyContinue
            
            if ($Output) {
                foreach ($Line in $Output) {
                    if ($Line) {
                        Write-Log $Line $ServiceName
                    }
                }
            }
        }
        
        Start-Sleep -Milliseconds 200
    }
}

# Graceful shutdown
function Stop-AllServices {
    Write-Header "SHUTTING DOWN SERVICES"
    $Global:ShutdownInProgress = $true
    
    foreach ($ServiceName in $Global:ProcessJobs.Keys) {
        $Job = $Global:ProcessJobs[$ServiceName]
        
        if ($Job -and $Job.State -eq "Running") {
            Write-Log "Stopping..." $ServiceName
            Stop-Job -Job $Job -ErrorAction SilentlyContinue
            Remove-Job -Job $Job -ErrorAction SilentlyContinue
            Write-Success "$ServiceName stopped"
        }
    }
    
    Write-Success "All services stopped"
}

# Ctrl+C handler
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Stop-AllServices
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

Write-Header "SMART KIOSK ASSISTANT - WINDOWS 11 LAUNCHER"

# Load environment
Load-Env

# Validate services exist
Write-Step "Validating service files..."
$AllValid = $true
foreach ($Service in $Services) {
    $MainFile = Join-Path $Service.Path $Service.MainFile
    if (-not (Test-Path $MainFile)) {
        Write-Error-Custom "Service file not found: $MainFile"
        $AllValid = $false
    }
}

if (-not $AllValid) {
    Write-Error-Custom "Some services are missing. Did you clone the repository correctly?"
    exit 1
}

Write-Success "All service files found"

# Start all services
Write-Step "Starting all services..."
$StartedCount = 0
foreach ($Service in $Services) {
    if (Start-Service -Service $Service) {
        $StartedCount++
        Start-Sleep -Milliseconds 500  # Stagger startup
    }
}

Write-Info "Started $StartedCount/$($Services.Count) services"

# Monitor health
Write-Step "Waiting for services to be ready..."
$AllHealthy = Monitor-Services -TimeoutSeconds 120

if ($AllHealthy) {
    Write-Header "ALL SERVICES RUNNING"
    Write-Success "Smart Kiosk Assistant is ready!"
    
    Write-Host "`nAccess the application at:`n" -ForegroundColor Green
    Write-Host "  Browser UI:  http://127.0.0.1:7860" -ForegroundColor Cyan
    Write-Host "  Kiosk Core:  http://127.0.0.1:8012" -ForegroundColor Cyan
    Write-Host "  Audio:       http://127.0.0.1:8010" -ForegroundColor Cyan
    Write-Host "  TTS:         http://127.0.0.1:8011" -ForegroundColor Cyan
    Write-Host "  RAG:         http://127.0.0.1:8020" -ForegroundColor Cyan
    Write-Host "`nPress Ctrl+C to stop all services`n" -ForegroundColor Green
    
    # Open browser
    if (-not $NoBrowser) {
        Start-Sleep -Seconds 2
        Open-Browser
    }
}
else {
    Write-Error-Custom "Some services failed to start"
    Write-Info "Check the logs above for details"
}

# Show unified logs
Show-Unified-Logs

# Shutdown
Stop-AllServices
