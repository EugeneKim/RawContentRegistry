# VMSS Custom Script Extension - Install .NET 10, create and run a Kestrel web app
# Logs to C:\WindowsAzure\Logs\vmss-kestrel-setup.log

$ErrorActionPreference = "Stop"
$logFile = "C:\WindowsAzure\Logs\vmss-kestrel-setup.log"

function Write-Log
{
	param([string]$Message)

	$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
	$entry = "[$timestamp] $Message"

	Write-Output $entry
	Add-Content -Path $logFile -Value $entry
}

try
{
	######################################################################################
	# Install .NET 10 SDK
	######################################################################################

	Write-Log "Downloading .NET 10 install script..."
	$dotnetInstallScript = "$env:TEMP\dotnet-install.ps1"
	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
	Invoke-WebRequest -Uri "https://dot.net/v1/dotnet-install.ps1" -OutFile $dotnetInstallScript -UseBasicParsing

	Write-Log "Installing .NET 10 SDK..."
	& $dotnetInstallScript -Channel 10.0 -InstallDir "C:\dotnet"

	# Add dotnet to PATH to environment

	$env:DOTNET_ROOT = "C:\dotnet"
	$env:PATH = "C:\dotnet;$env:PATH"
	[Environment]::SetEnvironmentVariable("DOTNET_ROOT", "C:\dotnet", "Machine")
	$machinePath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
	if ($machinePath -notlike "*C:\dotnet*")
	{
		[Environment]::SetEnvironmentVariable("PATH", "C:\dotnet;$machinePath", "Machine")
	}

	Write-Log "Installed dotnet version: $(& C:\dotnet\dotnet.exe --version)"

	######################################################################################
	# Create a minimal Kestrel web app
	######################################################################################

	$appDir = "C:\KestrelApp"
	Write-Log "Creating Kestrel web app at $appDir..."

	if (Test-Path $appDir)
	{
		Remove-Item $appDir -Recurse -Force
	}

	& C:\dotnet\dotnet.exe new web -o $appDir --force
	Write-Log "Scaffolded web project."

	# Add Windows Service hosting support

	Write-Log "Adding Microsoft.Extensions.Hosting.WindowsServices package..."
	& C:\dotnet\dotnet.exe add $appDir package Microsoft.Extensions.Hosting.WindowsServices
	Write-Log "WindowsServices package added."

	######################################################################################
	# Create default.html
	######################################################################################

	$wwwrootDir = Join-Path $appDir "wwwroot"

	if (-not (Test-Path $wwwrootDir))
	{
		New-Item -ItemType Directory -Path $wwwrootDir | Out-Null
	}

	$machineName = $env:COMPUTERNAME
	$htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
	<meta charset="UTF-8">
	<meta name="viewport" content="width=device-width, initial-scale=1.0">
	<title>Virtual Machine</title>
	<style>
		body { font-family: 'Segoe UI', sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; background: #f0f2f5; }
		.card { background: #fff; padding: 40px 60px; border-radius: 12px; box-shadow: 0 2px 12px rgba(0,0,0,0.1); text-align: center; }
		h1 { color: #0078d4; margin-bottom: 8px; }
		.machine-name { font-size: 2em; font-weight: bold; color: #333; margin: 16px 0; }
		.timestamp { color: #888; font-size: 0.9em; }
	</style>
</head>
<body>
	<div class="card">
		<h1>Virtual Machine Info</h1>
		<p>Machine Name:</p>
		<div class="machine-name">$machineName</div>
		<p class="timestamp">Page generated at: $([System.DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss")) UTC</p>
	</div>
</body>
</html>
"@
	Set-Content -Path (Join-Path $wwwrootDir "default.html") -Value $htmlContent -Encoding UTF8
	Write-Log "Created default.html for machine: $machineName"

	######################################################################################
    # Configure Program.cs to serve static files and default page on port 80
	######################################################################################

	$programCs = @"
var builder = WebApplication.CreateBuilder(new WebApplicationOptions
{
	Args = args,
	ContentRootPath = AppContext.BaseDirectory
});

builder.Host.UseWindowsService();
builder.WebHost.UseUrls("http://0.0.0.0:80");

var app = builder.Build();

app.UseDefaultFiles(new DefaultFilesOptions
{
	DefaultFileNames = new List<string> { "default.html" }
});
app.UseStaticFiles();

app.Run();
"@
	Set-Content -Path (Join-Path $appDir "Program.cs") -Value $programCs -Encoding UTF8
	Write-Log "Configured Program.cs with Kestrel on port 80."

	######################################################################################
	# Publish and run the app
	######################################################################################

	Write-Log "Publishing application..."
	& C:\dotnet\dotnet.exe publish $appDir -c Release -o "$appDir\publish"
	Write-Log "Publish complete."

	# Open firewall port 80

	Write-Log "Configuring firewall rule for port 80..."
	New-NetFirewallRule -DisplayName "Kestrel HTTP" -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow -ErrorAction SilentlyContinue

	# Register as a Windows service using sc.exe for persistence across reboots

	$exePath = "$appDir\publish\KestrelApp.exe"
	Write-Log "Registering Kestrel app as Windows service..."

	# Remove existing service if present (idempotent re-runs)

	$existingSvc = Get-Service -Name "KestrelWebApp" -ErrorAction SilentlyContinue
	if ($existingSvc)
	{
		& sc.exe stop "KestrelWebApp" 2>$null
		& sc.exe delete "KestrelWebApp"
		Start-Sleep -Seconds 2
	}

	& sc.exe create "KestrelWebApp" binPath= "$exePath" start= auto
	& sc.exe description "KestrelWebApp" "VMSS Kestrel Web App serving default.html"
	& sc.exe start "KestrelWebApp"

	# Wait briefly and verify the service is running

	Start-Sleep -Seconds 5
	$svc = Get-Service -Name "KestrelWebApp" -ErrorAction SilentlyContinue
	
	if ($svc -and $svc.Status -eq 'Running')
	{
		Write-Log "Service is confirmed running."
	}
	else
	{
		Write-Log "WARNING: Service status is $($svc.Status). Check Windows Event Log for details."
	}

	Write-Log "Kestrel web app is running as a Windows service on port 80."
	Write-Log "Setup completed successfully."
}
catch
{
	Write-Log "ERROR: $_"
	Write-Log $_.ScriptStackTrace
	throw
}