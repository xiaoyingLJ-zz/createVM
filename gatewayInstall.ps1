param(
 [string]
 $gatewayKey,
 [string]
 $vmdnsname
)

# init log setting
$logLoc = "$env:SystemDrive\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\"
if (! (Test-Path($logLoc)))
{
    New-Item -path $logLoc -type directory -Force
}
$logPath = "$logLoc\tracelog.log"
"Start to excute gatewayInstall.ps1. `n" | Out-File $logPath

function Now-Value()
{
    return (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}

function Throw-Error([string] $msg)
{
	try 
	{
		throw $msg
	} 
	catch 
	{
		$stack = $_.ScriptStackTrace
		Trace-Log "DMDTTP is failed: $msg`nStack:`n$stack"
	}

	throw $msg
}

function Trace-Log([string] $msg)
{
    $now = Now-Value
    try
    {
        "${now} $msg`n" | Out-File $logPath -Append
    }
    catch
    {
        #ignore any exception during trace
    }

}

function Run-Process([string] $process, [string] $arguments)
{
	Write-Verbose "Run-Process: $process $arguments"
	
	$errorFile = "$env:tmp\tmp$pid.err"
	$outFile = "$env:tmp\tmp$pid.out"
	"" | Out-File $outFile
	"" | Out-File $errorFile	

	$errVariable = ""

	if ([string]::IsNullOrEmpty($arguments))
	{
		$proc = Start-Process -FilePath $process -Wait -Passthru -NoNewWindow `
			-RedirectStandardError $errorFile -RedirectStandardOutput $outFile -ErrorVariable errVariable
	}
	else
	{
		$proc = Start-Process -FilePath $process -ArgumentList $arguments -Wait -Passthru -NoNewWindow `
			-RedirectStandardError $errorFile -RedirectStandardOutput $outFile -ErrorVariable errVariable
	}
	
	$errContent = [string] (Get-Content -Path $errorFile -Delimiter "!!!DoesNotExist!!!")
	$outContent = [string] (Get-Content -Path $outFile -Delimiter "!!!DoesNotExist!!!")

	Remove-Item $errorFile
	Remove-Item $outFile

	if($proc.ExitCode -ne 0 -or $errVariable -ne "")
	{		
		Throw-Error "Failed to run process: exitCode=$($proc.ExitCode), errVariable=$errVariable, errContent=$errContent, outContent=$outContent."
	}

	Trace-Log "Run-Process: ExitCode=$($proc.ExitCode), output=$outContent"

	if ([string]::IsNullOrEmpty($outContent))
	{
		return $outContent
	}

	return $outContent.Trim()
}

function Download-Gateway([string] $url, [string] $gwPath)
{
    try
    {
        $ErrorActionPreference = "Stop";
        $client = New-Object System.Net.WebClient
        $gatewayInfo = $client.DownloadString($uri)
        Trace-Log "Get gateway information successfully. $gatewayInfo"
        $psobject = $gatewayInfo | ConvertFrom-Json
        $downloadPath = $psobject | select -ExpandProperty "gatewayBitsLink"
        Trace-Log "Gateway download path: $downloadPath"
        $hashValue = $psobject | select -ExpandProperty "gatewayBitHash"
        Trace-Log "Expected gateway bit hash value: $hashValue"
        $client.DownloadFile($downloadPath, $gwPath)
        Trace-Log "Download gateway successfully. Gateway loc: $gwPath"
        return $hashValue
    }
    catch
    {
        Trace-Log "Fail to download gateway msi"
        Trace-Log $_.Exception.ToString()
        throw
    }
    return
}

function Verify-Signature([string] $gwPath, [string] $hashValue)
{
    Trace-Log "Begin to verify gateway signature."
    if ([string]::IsNullOrEmpty($gwPath))
    {
		Throw-Error "Gateway path is not specified"
    }

	if (!(Test-Path -Path $gwPath))
	{
		Throw-Error "Invalid gateway path: $gwPath"
	}
    $hasher = [System.Security.Cryptography.SHA256CryptoServiceProvider]::Create()
    $content = [System.IO.File]::OpenRead($gwPath)
    $hash = [System.Convert]::ToBase64String($hasher.ComputeHash($content))
    Trace-Log "Real gateway hash value: $hash"
    return ($hash -eq $hashValue)
}

function Install-Gateway([string] $gwPath, [string] $hashValue)
{
	if ([string]::IsNullOrEmpty($gwPath))
    {
		Throw-Error "Gateway path is not specified"
    }

	if (!(Test-Path -Path $gwPath))
	{
		Throw-Error "Invalid gateway path: $gwPath"
	}
    
    if(!(Verify-Signature $gwPath $hashValue))
    {
        Throw-Error "invalid gateway msi"
    }
	
	Trace-Log "Start Gateway installation"
	Run-Process "msiexec.exe" "/i gateway.msi /quiet /passive"		
	
	Start-Sleep -Seconds 30	

	Trace-Log "Installation of gateway is successful"
}

function Get-RegistryProperty([string] $keyPath, [string] $property)
{
	Trace-Log "Get-RegistryProperty: Get $property from $keyPath"
	if (! (Test-Path $keyPath))
	{
		Trace-Log "Get-RegistryProperty: $keyPath does not exist"
	}

	$keyReg = Get-Item $keyPath
	if (! ($keyReg.Property -contains $property))
	{
		Trace-Log "Get-RegistryProperty: $property does not exist"
		return ""
	}

	return $keyReg.GetValue($property)
}

function Get-InstalledFilePath()
{
	$filePath = Get-RegistryProperty "hklm:\Software\Microsoft\DataTransfer\DataManagementGateway\ConfigurationManager" "DiacmdPath"
	if ([string]::IsNullOrEmpty($filePath))
	{
		Throw-Error "Get-InstalledFilePath: Cannot find installed File Path"
	}
    Trace-Log "Gateway installation file: $filePath"

	return $filePath
}

function Register-Gateway([string] $instanceKey)
{
    Trace-Log "Register Agent"
	$filePath = Get-InstalledFilePath
	Run-Process $filePath "-k $instanceKey"

	Restart-Service DIAHostService -WarningAction:SilentlyContinue
    Trace-Log "Agent registration is successful!"
}

Trace-Log "Log file: $logLoc"
$uri = "https://wu.configuration.dataproxy.clouddatahub.net/GatewayClient/GatewayBits?version={0}&language={1}&platform={2}" -f "latest","en-US","x64"
Trace-Log "Configuration service url: $uri"
$gwPath= "$PWD\gateway.msi"
Trace-Log "Gateway download location: $gwPath"


$hashValue = Download-Gateway $uri $gwPath
Install-Gateway $gwPath $hashValue
Register-Gateway $gatewayKey

$regkey = "hklm:\Software\Microsoft\DataTransfer\DataManagementGateway\HostService"
Trace-Log "set externalhostname for gateway"
Set-ItemProperty -Path $regkey -Name ExternalHostName -Value $vmdnsname
Trace-Log "Successfully add VM DNS name $vmdnsname in Registry"