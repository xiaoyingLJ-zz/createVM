param(
 [string]
 $gatewayKey,
 [string]
 $vmdnsname
)

$logLoc = "$env:SystemDrive\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\"
if (! (Test-Path($logLoc)))
{
    Trace-Log "Can't find the log folder $logLoc, will create new directory"
    New-Item -path $logLoc -type directory -Force
    Trace-Log "Created the log folder $logLoc"
}
$logPath = "$logLoc\tracelog.log"
Trace-Log "Log file: $logLoc"
$uri = "https://wu.configuration.dataproxy.clouddatahub.net/GatewayClient/GatewayBits?version={0}&language={1}&platform={2}" -f "latest","en-US","x64"
Trace-Log "Configuration service url: $uri"
$gwPath= "$env:tmp\gateway.msi"
Trace-Log "Gateway download location: $gwPath"

Download-Gateway $uri $gwPath
Install-Gateway $gwPath
Register-Gateway $gatewayKey

$regkey = "hklm:\Software\Microsoft\DataTransfer\DataManagementGateway\HostService"
Set-ItemProperty -Path $regkey -Name ExternalHostName -Value $vmdnsname


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
    }
    catch
    {
        Trace-Log "Fail to download gateway msi"
        Trace-Log $_.Exception.ToString()
        throw
    }
}

function Verify-Signature([string] $gwPath, [string] $hashValue)
{
    Trace-Log "Begin to verify gateway signature."
    if ([string]::IsNullOrEmpty($gwPath))
    {
		throw "Gateway path is not specified"
    }

	if (!(Test-Path -Path $gwPath))
	{
		throw "Invalid gateway path: $gwPath"
	}
    $hasher = [System.Security.Cryptography.SHA256CryptoServiceProvider]::Create()
    $content = [System.IO.File]::OpenRead($gwPath)
    $hash = [System.Convert]::ToBase64String($hasher.ComputeHash($content))
    Trace-Log "Real gateway hash value: $hash"
    return ($hash -eq $hashValue)
}

function Install-Gateway([string] $gwPath)
{
	if ([string]::IsNullOrEmpty($gwPath))
    {
		throw "Gateway path is not specified"
    }

	if (!(Test-Path -Path $gwPath))
	{
		throw "Invalid gateway path: $gwPath"
	}
    
    if(!(Verify-Signature $gwPath $hashValue))
    {
        throw "invalid gateway msi"
    }
	
	Trace-Log "Copy Gateway installer from $gwPath to current location: $PWD"	
	Copy-Item -Path $gwPath -Destination $PWD -Force
	Trace-Log "Start Gateway installation"
	Run-Process "msiexec.exe" "/i gateway.msi /quiet /passive"		
	
	Start-Sleep -Seconds 30	

	Trace-Log "Installation of gateway is successful"

    Remove-Item $gwPath
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

