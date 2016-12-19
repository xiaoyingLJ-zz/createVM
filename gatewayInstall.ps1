param(
 [string]
 $gatewayKey,
 [string]
 $vmdnsname
)


$uri = "https://wu.configuration.dataproxy.clouddatahub.net/GatewayClient/GatewayBits?version={0}&language={1}&platform={2}" -f "latest","en-US","x64"
$gwPath= $env:SystemRoot + "\gateway.msi"
$client = New-Object System.Net.WebClient
$gatewayInfo = $client.DownloadString($uri) | ConvertTo-Json  | ConvertFrom-Json
$psobject = $gatewayInfo | ConvertFrom-Json
$downloadPath = $psobject | select -ExpandProperty "gatewayBitsLink"
$hashValue = $psobject | select -ExpandProperty "gatewayBitHash"
$client.DownloadFile($downloadPath, $gwPath)

function DMDTTP-RunProcess([string] $process, [string] $arguments)
{
	Write-Verbose "DMDTTP-RunProcess: $process $arguments"
	
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
		throw "Failed to run process: exitCode=$($proc.ExitCode), errVariable=$errVariable, errContent=$errContent, outContent=$outContent."
	}

	Write-Verbose "DMDTTP-RunProcess: ExitCode=$($proc.ExitCode), output=$outContent"

	if ([string]::IsNullOrEmpty($outContent))
	{
		return $outContent
	}

	return $outContent.Trim()
}

function Verify-Signature([string] $gwPath, [string] $hashValue)
{
    $hasher = [System.Security.Cryptography.SHA256CryptoServiceProvider]::Create()
    $content = [System.IO.File]::OpenRead($gwPath)
    $hash = [System.Convert]::ToBase64String($hasher.ComputeHash($content))
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
	
	Write-Verbose "Copy Gateway installer from $gwPath to current location: $PWD"	
	Copy-Item -Path $gwPath -Destination $PWD -Force
	Write-Verbose "Start Gateway installation"
	DMDTTP-RunProcess "msiexec.exe" "/i gateway.msi /quiet /passive"		
	
	Start-Sleep -Seconds 30	

	Write-Verbose "Installation of gateway is successful"
}

function GetRegistryProperty([string] $keyPath, [string] $property)
{
	Write-Verbose "GetRegistryProperty: Get $property from $keyPath"
	if (! (Test-Path $keyPath))
	{
		Write-Verbose "GetRegistryProperty: $keyPath does not exist"
	}

	$keyReg = Get-Item $keyPath
	if (! ($keyReg.Property -contains $property))
	{
		Write-Verbose "GetRegistryProperty: $property does not exist"
		return ""
	}

	return $keyReg.GetValue($property)
}

function Get-InstalledFilePath()
{
	$filePath = GetRegistryProperty "hklm:\Software\Microsoft\DataTransfer\DataManagementGateway\ConfigurationManager" "DiacmdPath"
	if ([string]::IsNullOrEmpty($filePath))
	{
		throw "Get-InstalledFilePath: Cannot find installed File Path"
	}

	return $filePath
}

function Register-Gateway([string] $instanceKey)
{
    Write-Verbose "Register Agent"
	$filePath = Get-InstalledFilePath
	DMDTTP-RunProcess $filePath "-k $instanceKey"

	Restart-Service DIAHostService -WarningAction:SilentlyContinue
    Write-Verbose "Agent registration is successful!"
}
Install-Gateway $gwPath
Register-Gateway $gatewayKey

$regkey = "hklm:\Software\Microsoft\DataTransfer\DataManagementGateway\HostService"
Set-ItemProperty -Path $regkey -Name ExternalHostName -Value $vmdnsname
