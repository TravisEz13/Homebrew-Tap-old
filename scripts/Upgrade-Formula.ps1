# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.
param(
    [Parameter(Mandatory)]
    [string]
    $FormulaPath,
    [ValidateSet('Stable', 'Preview', 'Lts', 'Daily')]
    [string]
    $Channel = 'Stable',
    [switch]
    $Force
)

$retryCount = 3
$retryIntervalSec = 15

$urlTemplate = 'https://github.com/PowerShell/PowerShell/releases/download/v{0}/powershell-{0}-osx-x64.tar.gz'
Switch ($Channel) {
    'Stable' {
        $metadata = Invoke-RestMethod 'https://aka.ms/pwsh-buildinfo-stable' -MaximumRetryCount $retryCount -RetryIntervalSec $retryIntervalSec
    }
    'Lts' {
        $metadata = Invoke-RestMethod 'https://aka.ms/pwsh-buildinfo-lts' -MaximumRetryCount $retryCount -RetryIntervalSec $retryIntervalSec
    }
    'Preview' {
        $metadata = Invoke-RestMethod 'https://aka.ms/pwsh-buildinfo-preview' -MaximumRetryCount $retryCount -RetryIntervalSec $retryIntervalSec
    }
    'Daily' {
        $metadata = Invoke-RestMethod 'https://aka.ms/pwsh-buildinfo-Daily' -MaximumRetryCount $retryCount -RetryIntervalSec $retryIntervalSec
        $urlTemplate = "https://pscoretestdata.blob.core.windows.net/$($metadata.blobname)/powershell-{0}-osx-x64.tar.gz"
    }
    default {
        throw "Invalid channel: $Channel"
    }
}

$expectedVersion = $metadata.ReleaseTag -replace '^v'
Write-Verbose "Expected version: $expectedVersion" -verbose

$ErrorActionPreference = "stop"

$formulaString = Get-Content -Path $FormulaPath

function Get-FormulaString
{
    param(
        [Parameter(Mandatory)]
        [object[]]
        $OriginalFomula,

        [string]
        $Pattern,

        [Parameter(Mandatory)]
        [string]
        $PropertyName,

        [switch] $Increment
    )

    if ($Pattern) {
        $actualPattern = $Pattern
    }
    elseif ($Increment.IsPresent) {
        $actualPattern = '^\s*{0}\s*.*$' -f $PropertyName
    }
    else {
        $actualPattern = '^\s*{0}\s*"([^"]*)"$' -f $PropertyName
    }

    Write-Verbose "Finding $PropertyName uning $actualPattern"

    return $OriginalFomula | Select-String -Raw -Pattern $actualPattern
}

function Update-Formula {
    param(
        [Parameter(Mandatory)]
        [object[]]
        $OriginalFomula,

        [Parameter(Mandatory)]
        [System.Text.StringBuilder]
        $CurrentFormula,

        [string]
        $Pattern,

        [Parameter(Mandatory, ParameterSetName='newValue')]
        [string]
        $NewValue,

        [Parameter(Mandatory, ParameterSetName='increment')]
        [switch]
        $Increment,

        [Parameter(Mandatory)]
        [string]
        $PropertyName
    )

    $propertyString = Get-FormulaString -OriginalFomula $OriginalFomula -PropertyName $PropertyName -Pattern $Pattern -Increment:$Increment.IsPresent
    if(!$propertyString)
    {
        throw "could not find $PropertyName"
    }

    if($Increment.IsPresent)
    {
        $actualValue = ([int] ($propertyString.Replace($PropertyName,'').Trim()))
        $actualValue = $actualValue + 1
        $newPropertyString = $propertyString -replace "$PropertyName\s*\d*", ('{0} {1}' -f $PropertyName, $actualValue)
    }
    else {
        $newPropertyString = $propertyString -replace '"([^"]*)"', ('"{0}"' -f $NewValue)
    }

    Write-Verbose "replacing '$propertyString' with '$newPropertyString'" -Verbose
    $null = $CurrentFormula.Replace($propertyString, $newPropertyString)
}

Write-Host "::set-env name=NEW_FORMULA_VERSION::$expectedVersion"

$expectedUrl = $urlTemplate -f $expectedVersion
Write-Verbose "new url: $expectedUrl" -Verbose

$urlString = Get-FormulaString -OriginalFomula $formulaString -PropertyName 'url'

$urlPattern = '"([^"]*)"'
if (! ($urlString -match "$urlPattern")) {
    throw "url not found"
}

$url = $Matches.1
Write-Verbose "existing url: $url" -Verbose

$urlMatch = $url -eq $expectedUrl
Write-Verbose "url Match: $urlMatch" -Verbose
if ($urlMatch -and !$Force.IsPresent) {
    Write-Verbose "Forumla is up to date, exiting." -Verbose
    return
}

Write-Verbose "Updating formula ..." -Verbose

$newFormula = [System.Text.StringBuilder]::new($formulaString -join [System.Environment]::NewLine)

Update-Formula -PropertyName 'url' -CurrentFormula $newFormula -NewValue $expectedUrl -OriginalFomula $formulaString

Update-Formula -PropertyName 'version_scheme' -CurrentFormula $newFormula -Increment -OriginalFomula $formulaString

#assert_equal "7.1.0-preview.1",
$versionPattern = '(\d*\.\d*\.\d*(-\w*(\.\d*)?)?)'
Update-Formula -PropertyName 'assert_equal_version' -CurrentFormula $newFormula -NewValue $expectedVersion -Pattern ('^\s*assert_equal\s*"{0}",$' -f $versionPattern)  -OriginalFomula $formulaString

Write-Verbose "Getting file to calculate hash..." -Verbose
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri $expectedUrl -OutFile ./FileToHash.file

$hash = (Get-FileHash -Path ./FileToHash.file -Algorithm SHA256).Hash.ToLower()
Remove-Item ./FileToHash.file
Write-Verbose "hash: $hash"

Update-Formula -PropertyName 'sha256' -CurrentFormula $newFormula -NewValue $hash -OriginalFomula $formulaString

$null = $newFormula.Replace($versionString,$newVersionSchemeString)

$newFormula.ToString() | Out-File -Encoding utf8NoBOM -FilePath $FormulaPath
