[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("ListSkus", "CreateUser", "BulkCreateUsers")]
    [string]$Action,

    [string]$TenantId = $env:GRAPH_TENANT_ID,
    [string]$ClientId = $env:GRAPH_CLIENT_ID,
    [string]$ClientSecret = $env:GRAPH_CLIENT_SECRET,
    [string]$EnvPath = ".env",

    [string]$DisplayName,
    [string]$Alias,
    [string]$UserPrincipalName,
    [string]$Password,

    [bool]$ForceChangePasswordNextSignIn = $true,

    [ValidatePattern("^[A-Z]{2}$")]
    [string]$UsageLocation,

    [string]$SkuId,
    [string]$SkuPartNumber,
    [string[]]$DisabledPlanIds = @(),
    [string]$CsvPath,

    [switch]$OutputJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:SubscribedSkusCache = $null

function Require-Value {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "Missing required value for '$Name'."
    }
}

function Get-TrimmedString {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $stringValue = [string]$Value
    if ([string]::IsNullOrWhiteSpace($stringValue)) {
        return $null
    }

    return $stringValue.Trim()
}

function Get-EffectiveValue {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$PrimaryValue,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$FallbackValue
    )

    $resolvedPrimary = Get-TrimmedString -Value $PrimaryValue
    if ($null -ne $resolvedPrimary) {
        return $resolvedPrimary
    }

    return Get-TrimmedString -Value $FallbackValue
}

function Resolve-ScriptRelativePath {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return Join-Path -Path $PSScriptRoot -ChildPath $Path
    }

    return $Path
}

function New-RandomPassword {
    param(
        [int]$Length = 20
    )

    $upper = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    $lower = "abcdefghijkmnopqrstuvwxyz"
    $digits = "23456789"
    $symbols = "!@$%*_-+=?"
    $all = ($upper + $lower + $digits + $symbols).ToCharArray()

    $passwordChars = New-Object System.Collections.Generic.List[char]
    $passwordChars.Add($upper[(Get-Random -Minimum 0 -Maximum $upper.Length)])
    $passwordChars.Add($lower[(Get-Random -Minimum 0 -Maximum $lower.Length)])
    $passwordChars.Add($digits[(Get-Random -Minimum 0 -Maximum $digits.Length)])
    $passwordChars.Add($symbols[(Get-Random -Minimum 0 -Maximum $symbols.Length)])

    for ($i = $passwordChars.Count; $i -lt $Length; $i++) {
        $passwordChars.Add($all[(Get-Random -Minimum 0 -Maximum $all.Length)])
    }

    return (-join ($passwordChars | Sort-Object { Get-Random }))
}

function Get-FriendlyError {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        return $ErrorRecord.ErrorDetails.Message
    }

    return $ErrorRecord.Exception.Message
}

function Import-DotEnvFile {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Path
    )

    $values = @{}
    $resolvedPath = Resolve-ScriptRelativePath -Path $Path

    if ([string]::IsNullOrWhiteSpace($resolvedPath) -or -not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        return $values
    }

    foreach ($line in Get-Content -LiteralPath $resolvedPath) {
        $trimmedLine = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmedLine) -or $trimmedLine.StartsWith("#")) {
            continue
        }

        $parts = $trimmedLine -split "=", 2
        if ($parts.Count -ne 2) {
            continue
        }

        $key = Get-TrimmedString -Value $parts[0]
        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }

        $value = $parts[1].Trim()
        if ($value.Length -ge 2) {
            $startsWithSingleQuote = $value.StartsWith("'")
            $endsWithSingleQuote = $value.EndsWith("'")
            $startsWithDoubleQuote = $value.StartsWith('"')
            $endsWithDoubleQuote = $value.EndsWith('"')

            if (($startsWithSingleQuote -and $endsWithSingleQuote) -or ($startsWithDoubleQuote -and $endsWithDoubleQuote)) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        $values[$key] = $value
    }

    return $values
}

function ConvertTo-BooleanValue {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [bool]$DefaultValue
    )

    $trimmedValue = Get-TrimmedString -Value $Value
    if ($null -eq $trimmedValue) {
        return $DefaultValue
    }

    switch ($trimmedValue.ToLowerInvariant()) {
        "true" { return $true }
        "false" { return $false }
        "1" { return $true }
        "0" { return $false }
        "yes" { return $true }
        "no" { return $false }
        "y" { return $true }
        "n" { return $false }
        default { throw "Could not parse boolean value '$trimmedValue'. Use true/false, yes/no, or 1/0." }
    }
}

function ConvertTo-StringArray {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value,

        [string[]]$DefaultValue = @()
    )

    $trimmedValue = Get-TrimmedString -Value $Value
    if ($null -eq $trimmedValue) {
        return @($DefaultValue | ForEach-Object { Get-TrimmedString -Value $_ } | Where-Object { $null -ne $_ })
    }

    return @(
        $trimmedValue -split "[,;]" |
        ForEach-Object { Get-TrimmedString -Value $_ } |
        Where-Object { $null -ne $_ }
    )
}

function Get-UsageLocationValue {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$FallbackValue
    )

    $resolvedValue = Get-EffectiveValue -PrimaryValue $Value -FallbackValue $FallbackValue
    if ($null -eq $resolvedValue) {
        return $null
    }

    $resolvedValue = $resolvedValue.ToUpperInvariant()
    if ($resolvedValue -notmatch "^[A-Z]{2}$") {
        throw "UsageLocation must be a two-letter ISO country code, for example 'US' or 'GB'."
    }

    return $resolvedValue
}

function Get-RowValue {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Row,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $Row.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return Get-TrimmedString -Value $property.Value
}

function Get-GraphToken {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$ClientId,

        [Parameter(Mandatory = $true)]
        [string]$ClientSecret
    )

    $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $body = @{
        client_id     = $ClientId
        scope         = "https://graph.microsoft.com/.default"
        client_secret = $ClientSecret
        grant_type    = "client_credentials"
    }

    $tokenResponse = Invoke-RestMethod -Method Post -Uri $tokenUri -Body $body -ContentType "application/x-www-form-urlencoded"
    Require-Value -Name "access token" -Value $tokenResponse.access_token

    return $tokenResponse.access_token
}

function Invoke-GraphRequest {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Get", "Post", "Patch")]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Body
    )

    $uri = "https://graph.microsoft.com/v1.0$Path"
    $headers = @{
        Authorization = "Bearer $Token"
    }

    if ($null -ne $Body) {
        $jsonBody = $Body | ConvertTo-Json -Depth 10
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -ContentType "application/json" -Body $jsonBody
    }

    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

function Get-SubscribedSkus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    if ($null -ne $script:SubscribedSkusCache) {
        return $script:SubscribedSkusCache
    }

    $response = Invoke-GraphRequest -Method Get -Path "/subscribedSkus" -Token $Token
    $script:SubscribedSkusCache = @($response.value)
    return $script:SubscribedSkusCache
}

function Resolve-Sku {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token,

        [string]$SkuId,
        [string]$SkuPartNumber
    )

    if ([string]::IsNullOrWhiteSpace($SkuId) -and [string]::IsNullOrWhiteSpace($SkuPartNumber)) {
        return $null
    }

    $skus = Get-SubscribedSkus -Token $Token
    $matchedSku = $null

    if (-not [string]::IsNullOrWhiteSpace($SkuId)) {
        $matchedSku = $skus | Where-Object { $_.skuId -eq $SkuId } | Select-Object -First 1
    }
    else {
        $matchedSku = $skus | Where-Object { $_.skuPartNumber -eq $SkuPartNumber } | Select-Object -First 1
    }

    if ($null -eq $matchedSku) {
        if (-not [string]::IsNullOrWhiteSpace($SkuId)) {
            throw "Could not find a subscribed SKU with skuId '$SkuId'. Run -Action ListSkus first."
        }

        throw "Could not find a subscribed SKU with skuPartNumber '$SkuPartNumber'. Run -Action ListSkus first."
    }

    return $matchedSku
}

function Set-UserUsageLocation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [string]$UserId,

        [Parameter(Mandatory = $true)]
        [string]$UsageLocation
    )

    Invoke-GraphRequest -Method Patch -Path "/users/$UserId" -Token $Token -Body @{
        usageLocation = $UsageLocation
    } | Out-Null
}

function New-UserProvisioningRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token,

        [string]$DisplayName,
        [string]$Alias,
        [string]$UserPrincipalName,
        [string]$Password,

        [Parameter(Mandatory = $true)]
        [bool]$ForceChangePasswordNextSignIn,

        [string]$UsageLocation,
        [string]$SkuId,
        [string]$SkuPartNumber,
        [string[]]$DisabledPlanIds = @()
    )

    $DisplayName = Get-TrimmedString -Value $DisplayName
    $Alias = Get-TrimmedString -Value $Alias
    $UserPrincipalName = Get-TrimmedString -Value $UserPrincipalName
    $Password = Get-TrimmedString -Value $Password
    $UsageLocation = Get-UsageLocationValue -Value $UsageLocation
    $SkuId = Get-TrimmedString -Value $SkuId
    $SkuPartNumber = Get-TrimmedString -Value $SkuPartNumber
    $DisabledPlanIds = @($DisabledPlanIds | ForEach-Object { Get-TrimmedString -Value $_ } | Where-Object { $null -ne $_ })

    Require-Value -Name "DisplayName" -Value $DisplayName
    Require-Value -Name "UserPrincipalName" -Value $UserPrincipalName

    if ([string]::IsNullOrWhiteSpace($Alias)) {
        if ($UserPrincipalName -match "@") {
            $Alias = $UserPrincipalName.Split("@")[0]
        }
        else {
            throw "Alias is required when UserPrincipalName does not contain '@'."
        }
    }

    if ((-not [string]::IsNullOrWhiteSpace($SkuId) -or -not [string]::IsNullOrWhiteSpace($SkuPartNumber)) -and [string]::IsNullOrWhiteSpace($UsageLocation)) {
        throw "UsageLocation is required when assigning a license."
    }

    $resolvedSku = Resolve-Sku -Token $Token -SkuId $SkuId -SkuPartNumber $SkuPartNumber
    $initialPassword = $Password

    if ([string]::IsNullOrWhiteSpace($initialPassword)) {
        $initialPassword = New-RandomPassword
    }

    $createdUser = $null
    try {
        $createdUser = Invoke-GraphRequest -Method Post -Path "/users" -Token $Token -Body @{
            accountEnabled    = $true
            displayName       = $DisplayName
            mailNickname      = $Alias
            userPrincipalName = $UserPrincipalName
            passwordProfile   = @{
                forceChangePasswordNextSignIn = $ForceChangePasswordNextSignIn
                password                      = $initialPassword
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($UsageLocation)) {
            Set-UserUsageLocation -Token $Token -UserId $createdUser.id -UsageLocation $UsageLocation
        }

        if ($null -ne $resolvedSku) {
            Invoke-GraphRequest -Method Post -Path "/users/$($createdUser.id)/assignLicense" -Token $Token -Body @{
                addLicenses = @(
                    @{
                        skuId         = $resolvedSku.skuId
                        disabledPlans = $DisabledPlanIds
                    }
                )
                removeLicenses = @()
            } | Out-Null
        }
    }
    catch {
        if ($null -ne $createdUser) {
            $partialMessage = "User '$($createdUser.userPrincipalName)' was created with id '$($createdUser.id)', but a later step failed. "
            throw ($partialMessage + (Get-FriendlyError -ErrorRecord $_))
        }

        throw
    }

    return [pscustomobject]@{
        userId                        = $createdUser.id
        displayName                   = $createdUser.displayName
        userPrincipalName             = $createdUser.userPrincipalName
        initialPassword               = $initialPassword
        forceChangePasswordNextSignIn = $ForceChangePasswordNextSignIn
        usageLocation                 = $UsageLocation
        licenseAssigned               = ($null -ne $resolvedSku)
        licenseSkuPartNumber          = if ($null -ne $resolvedSku) { $resolvedSku.skuPartNumber } else { $null }
        licenseSkuId                  = if ($null -ne $resolvedSku) { $resolvedSku.skuId } else { $null }
    }
}

function Show-Result {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,

        [switch]$OutputJson
    )

    if ($OutputJson) {
        $Value | ConvertTo-Json -Depth 10
        return
    }

    $Value
}

function Show-BulkProvisioningResult {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Summary,

        [Parameter(Mandatory = $true)]
        [object[]]$Results,

        [switch]$OutputJson
    )

    if ($OutputJson) {
        [pscustomobject]@{
            summary = $Summary
            results = $Results
        } | ConvertTo-Json -Depth 10
        return
    }

    $Summary
    $Results
}

try {
    $dotEnvValues = Import-DotEnvFile -Path $EnvPath
    $TenantId = Get-EffectiveValue -PrimaryValue $TenantId -FallbackValue $dotEnvValues["GRAPH_TENANT_ID"]
    $ClientId = Get-EffectiveValue -PrimaryValue $ClientId -FallbackValue $dotEnvValues["GRAPH_CLIENT_ID"]
    $ClientSecret = Get-EffectiveValue -PrimaryValue $ClientSecret -FallbackValue $dotEnvValues["GRAPH_CLIENT_SECRET"]

    Require-Value -Name "TenantId" -Value $TenantId
    Require-Value -Name "ClientId" -Value $ClientId
    Require-Value -Name "ClientSecret" -Value $ClientSecret

    if ($Action -eq "CreateUser") {
        Require-Value -Name "DisplayName" -Value $DisplayName
        Require-Value -Name "UserPrincipalName" -Value $UserPrincipalName
    }
    elseif ($Action -eq "BulkCreateUsers") {
        Require-Value -Name "CsvPath" -Value $CsvPath
    }

    $token = Get-GraphToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

    switch ($Action) {
        "ListSkus" {
            $skus = Get-SubscribedSkus -Token $token | Sort-Object skuPartNumber | ForEach-Object {
                $enabledUnits = 0
                if ($_.prepaidUnits -and $null -ne $_.prepaidUnits.enabled) {
                    $enabledUnits = [int]$_.prepaidUnits.enabled
                }

                $consumedUnits = 0
                if ($null -ne $_.consumedUnits) {
                    $consumedUnits = [int]$_.consumedUnits
                }

                [pscustomobject]@{
                    skuPartNumber = $_.skuPartNumber
                    skuId         = $_.skuId
                    enabledUnits  = $enabledUnits
                    consumedUnits = $consumedUnits
                    availableUnits = ($enabledUnits - $consumedUnits)
                }
            }

            Show-Result -Value $skus -OutputJson:$OutputJson
            break
        }

        "CreateUser" {
            $result = New-UserProvisioningRecord `
                -Token $token `
                -DisplayName $DisplayName `
                -Alias $Alias `
                -UserPrincipalName $UserPrincipalName `
                -Password $Password `
                -ForceChangePasswordNextSignIn $ForceChangePasswordNextSignIn `
                -UsageLocation $UsageLocation `
                -SkuId $SkuId `
                -SkuPartNumber $SkuPartNumber `
                -DisabledPlanIds $DisabledPlanIds

            Show-Result -Value $result -OutputJson:$OutputJson
            break
        }

        "BulkCreateUsers" {
            $resolvedCsvPath = (Resolve-Path -LiteralPath $CsvPath).Path
            $rows = @(Import-Csv -LiteralPath $resolvedCsvPath)

            if ($rows.Count -eq 0) {
                throw "CSV file '$resolvedCsvPath' contains no data rows."
            }

            $results = New-Object System.Collections.Generic.List[object]
            $succeeded = 0
            $failed = 0

            for ($index = 0; $index -lt $rows.Count; $index++) {
                $row = $rows[$index]
                $rowNumber = $index + 2

                $rowDisplayName = Get-EffectiveValue -PrimaryValue (Get-RowValue -Row $row -Name "DisplayName") -FallbackValue $DisplayName
                $rowAlias = Get-EffectiveValue -PrimaryValue (Get-RowValue -Row $row -Name "Alias") -FallbackValue $Alias
                $rowUserPrincipalName = Get-EffectiveValue -PrimaryValue (Get-RowValue -Row $row -Name "UserPrincipalName") -FallbackValue $UserPrincipalName
                $rowPassword = Get-EffectiveValue -PrimaryValue (Get-RowValue -Row $row -Name "Password") -FallbackValue $Password
                $rowUsageLocation = Get-UsageLocationValue -Value (Get-RowValue -Row $row -Name "UsageLocation") -FallbackValue $UsageLocation
                $rowSkuId = Get-EffectiveValue -PrimaryValue (Get-RowValue -Row $row -Name "SkuId") -FallbackValue $SkuId
                $rowSkuPartNumber = Get-EffectiveValue -PrimaryValue (Get-RowValue -Row $row -Name "SkuPartNumber") -FallbackValue $SkuPartNumber
                $rowForceChangePasswordNextSignIn = ConvertTo-BooleanValue -Value (Get-RowValue -Row $row -Name "ForceChangePasswordNextSignIn") -DefaultValue $ForceChangePasswordNextSignIn
                $rowDisabledPlanIds = ConvertTo-StringArray -Value (Get-RowValue -Row $row -Name "DisabledPlanIds") -DefaultValue $DisabledPlanIds

                try {
                    $provisionedUser = New-UserProvisioningRecord `
                        -Token $token `
                        -DisplayName $rowDisplayName `
                        -Alias $rowAlias `
                        -UserPrincipalName $rowUserPrincipalName `
                        -Password $rowPassword `
                        -ForceChangePasswordNextSignIn $rowForceChangePasswordNextSignIn `
                        -UsageLocation $rowUsageLocation `
                        -SkuId $rowSkuId `
                        -SkuPartNumber $rowSkuPartNumber `
                        -DisabledPlanIds $rowDisabledPlanIds

                    $results.Add([pscustomobject]@{
                        rowNumber          = $rowNumber
                        status             = "Succeeded"
                        displayName        = $provisionedUser.displayName
                        userPrincipalName  = $provisionedUser.userPrincipalName
                        userId             = $provisionedUser.userId
                        initialPassword    = $provisionedUser.initialPassword
                        usageLocation      = $provisionedUser.usageLocation
                        licenseAssigned    = $provisionedUser.licenseAssigned
                        licenseSkuPartNumber = $provisionedUser.licenseSkuPartNumber
                        licenseSkuId       = $provisionedUser.licenseSkuId
                        error              = $null
                    })
                    $succeeded++
                }
                catch {
                    $results.Add([pscustomobject]@{
                        rowNumber          = $rowNumber
                        status             = "Failed"
                        displayName        = $rowDisplayName
                        userPrincipalName  = $rowUserPrincipalName
                        userId             = $null
                        initialPassword    = $null
                        usageLocation      = $rowUsageLocation
                        licenseAssigned    = $false
                        licenseSkuPartNumber = $rowSkuPartNumber
                        licenseSkuId       = $rowSkuId
                        error              = Get-FriendlyError -ErrorRecord $_
                    })
                    $failed++
                }
            }

            $summary = [pscustomobject]@{
                csvPath   = $resolvedCsvPath
                totalRows = $rows.Count
                succeeded = $succeeded
                failed    = $failed
            }

            Show-BulkProvisioningResult -Summary $summary -Results @($results) -OutputJson:$OutputJson

            if ($failed -gt 0) {
                exit 2
            }

            break
        }
    }
}
catch {
    $message = Get-FriendlyError -ErrorRecord $_
    Write-Error $message
    exit 1
}
