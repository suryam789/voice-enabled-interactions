# =============================================================================
# stop_kiosk.ps1
# Smart Kiosk Assistant - Service Shutdown Script
#
# Gracefully stops all running services
#
# Usage: powershell -ExecutionPolicy Bypass -File stop_kiosk.ps1
# =============================================================================

param(
    [switch]$Force = $false  # Force kill processes
)

$ErrorActionPreference = "Continue"
$WarningPreference = "SilentlyContinue"

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
    Write-Host "[*] $Message" -ForegroundColor Yellow
}

function Write-Error-Custom {
    param([string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Red
}

Write-Header "SMART KIOSK ASSISTANT - SHUTDOWN"

$Services = @("text-to-speech", "audio-analyzer", "rag-service", "kiosk-core", "kiosk-ui")
$Ports = @{
    "text-to-speech" = 8011
    "audio-analyzer" = 8010
    "rag-service" = 8020
    "kiosk-core" = 8012
    "kiosk-ui" = 7860
}

$StoppedCount = 0

foreach ($Service in $Services) {
    $Port = $Ports[$Service]
    
    try {
        # Find processes listening on the port
        $ProcessInfo = netstat -ano | Select-String ":$Port " | Select-String "LISTENING"
        
        if ($ProcessInfo) {
            $Matches = [regex]::Matches($ProcessInfo, '(\d+)\s+LISTENING')
            foreach ($Match in $Matches) {
                $ProcessId = $Match.Groups[1].Value
                
                if ($Force) {
                    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
                    Write-Success "$Service (PID $ProcessId) force stopped"
                }
                else {
                    Stop-Process -Id $ProcessId -ErrorAction SilentlyContinue
                    Write-Success "$Service (PID $ProcessId) stopped"
                }
                
                $StoppedCount++
            }
        }
        else {
            Write-Info "$Service is not running"
        }
    }
    catch {
        Write-Error-Custom "Error stopping $Service : $_"
    }
}

Write-Header "SHUTDOWN COMPLETE"
Write-Success "Stopped $StoppedCount service(s)"

Write-Info "All services are now stopped."
Write-Host "`nTo start again, run: powershell -ExecutionPolicy Bypass -File start_kiosk.ps1`n" -ForegroundColor Green

Start-Sleep -Milliseconds 500
