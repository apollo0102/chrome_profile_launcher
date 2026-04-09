[CmdletBinding()]
param(
    [string]$EnvPath = ".env",
    [string]$BaseName = $env:CHROME_PROFILE_BASE_NAME,
    [string]$ProfileRoot = $env:CHROME_PROFILE_ROOT,
    [string]$ChromePath = $env:CHROME_PATH,
    [string]$ProxyFile = $env:CHROME_PROXY_FILE,
    [string]$CurrentProxy = $env:CURRENT_PROXY,
    [string]$ProfileRange = $env:CHROME_PROFILE_RANGE,
    [int]$Count = 0,
    [string[]]$Urls
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Get-EffectiveInt {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$PrimaryValue,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$FallbackValue,

        [int]$DefaultValue = 0
    )

    $resolvedValue = Get-EffectiveValue -PrimaryValue $PrimaryValue -FallbackValue $FallbackValue
    if ($null -eq $resolvedValue) {
        return $DefaultValue
    }

    $parsedValue = 0
    if (-not [int]::TryParse($resolvedValue, [ref]$parsedValue)) {
        throw "Count must be an integer. Received '$resolvedValue'."
    }

    return $parsedValue
}

function Get-NonNegativeInt {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $resolvedValue = Get-TrimmedString -Value $Value
    if ($null -eq $resolvedValue) {
        return $null
    }

    $parsedValue = 0
    if (-not [int]::TryParse($resolvedValue, [ref]$parsedValue)) {
        throw "$Name must be an integer. Received '$resolvedValue'."
    }

    if ($parsedValue -lt 0) {
        throw "$Name must be at least 0."
    }

    return $parsedValue
}

function Test-IsProfileRangeValue {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    $resolvedValue = Get-TrimmedString -Value $Value
    if ($null -eq $resolvedValue) {
        return $false
    }

    $normalizedValue = $resolvedValue.Trim()
    if ($normalizedValue.StartsWith("[") -and $normalizedValue.EndsWith("]")) {
        return $true
    }

    return $normalizedValue -match "^\s*\d+\s*([,;-]\s*\d+\s*)?$"
}

function Resolve-ProfileNumberRange {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$PrimaryValue,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$FallbackValue,

        [int]$FallbackCount = 0
    )

    $resolvedRange = Get-EffectiveValue -PrimaryValue $PrimaryValue -FallbackValue $FallbackValue
    if ($null -ne $resolvedRange) {
        $normalizedRange = $resolvedRange.Trim()

        if ($normalizedRange.StartsWith("[") -and $normalizedRange.EndsWith("]")) {
            $normalizedRange = $normalizedRange.Substring(1, $normalizedRange.Length - 2).Trim()
        }

        $parts = @(
            $normalizedRange -split "\s*[,;-]\s*" |
            ForEach-Object { Get-TrimmedString -Value $_ } |
            Where-Object { $null -ne $_ }
        )

        if ($parts.Count -lt 1 -or $parts.Count -gt 2) {
            throw "CHROME_PROFILE_RANGE must contain one integer like [5] or two integers like [4,7]."
        }

        $start = 0
        $end = 0

        if (-not [int]::TryParse($parts[0], [ref]$start)) {
            throw "CHROME_PROFILE_RANGE must contain integers, for example [5] or [4,7]."
        }

        if ($parts.Count -eq 1) {
            $end = $start
        }
        elseif (-not [int]::TryParse($parts[1], [ref]$end)) {
            throw "CHROME_PROFILE_RANGE must contain integers, for example [5] or [4,7]."
        }

        if ($start -lt 1 -or $end -lt 1) {
            throw "CHROME_PROFILE_RANGE values must be at least 1."
        }

        if ($end -lt $start) {
            throw "CHROME_PROFILE_RANGE end must be greater than or equal to start."
        }

        return [pscustomobject]@{
            Start = $start
            End   = $end
            Count = ($end - $start + 1)
        }
    }

    if ($FallbackCount -lt 1) {
        throw "Set CHROME_PROFILE_RANGE like [5] or [4,7], or set CHROME_PROFILE_COUNT to at least 1."
    }

    return [pscustomobject]@{
        Start = 1
        End   = $FallbackCount
        Count = $FallbackCount
    }
}

function Get-EffectiveUrlList {
    param(
        [string[]]$PrimaryUrls,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$FallbackUrls
    )

    if ($null -ne $PrimaryUrls -and $PrimaryUrls.Count -gt 0) {
        return @(
            $PrimaryUrls |
            ForEach-Object { Get-TrimmedString -Value $_ } |
            Where-Object { $null -ne $_ }
        )
    }

    $resolvedFallback = Get-TrimmedString -Value $FallbackUrls
    if ($null -ne $resolvedFallback) {
        return @(
            $resolvedFallback -split "[,;]" |
            ForEach-Object { Get-TrimmedString -Value $_ } |
            Where-Object { $null -ne $_ }
        )
    }

    return @(
        "https://contactout.com/",
        "https://outlook.com/"
    )
}

function Get-ProxyListFromFile {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Path
    )

    $resolvedPath = Resolve-ScriptRelativePath -Path $Path
    if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
        return @()
    }

    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Proxy file not found: $resolvedPath"
    }

    $proxies = New-Object System.Collections.Generic.List[string]
    foreach ($line in Get-Content -LiteralPath $resolvedPath) {
        $trimmedLine = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmedLine) -or $trimmedLine.StartsWith("#") -or $trimmedLine.StartsWith("//")) {
            continue
        }

        if ($trimmedLine.EndsWith(",")) {
            $trimmedLine = $trimmedLine.Substring(0, $trimmedLine.Length - 1).TrimEnd()
        }

        if ($trimmedLine.Length -ge 2) {
            $startsWithSingleQuote = $trimmedLine.StartsWith("'")
            $endsWithSingleQuote = $trimmedLine.EndsWith("'")
            $startsWithDoubleQuote = $trimmedLine.StartsWith('"')
            $endsWithDoubleQuote = $trimmedLine.EndsWith('"')

            if (($startsWithSingleQuote -and $endsWithSingleQuote) -or ($startsWithDoubleQuote -and $endsWithDoubleQuote)) {
                $trimmedLine = $trimmedLine.Substring(1, $trimmedLine.Length - 2)
            }
        }

        $resolvedProxy = Get-TrimmedString -Value $trimmedLine
        if ($null -ne $resolvedProxy) {
            $proxies.Add($resolvedProxy)
        }
    }

    if ($proxies.Count -lt 1) {
        throw "No proxies found in $resolvedPath. Add one proxy URL per line."
    }

    return $proxies
}

function ConvertTo-ProxyConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProxyUrl
    )

    try {
        $uri = [System.Uri]$ProxyUrl
    }
    catch {
        throw "Proxy is not a valid URL: $ProxyUrl"
    }

    if ([string]::IsNullOrWhiteSpace($uri.Scheme)) {
        throw "Proxy is missing a scheme: $ProxyUrl"
    }

    if ([string]::IsNullOrWhiteSpace($uri.Host)) {
        throw "Proxy is missing a host: $ProxyUrl"
    }

    if ($uri.Port -lt 1) {
        throw "Proxy is missing a port: $ProxyUrl"
    }

    $username = ""
    $password = ""
    if (-not [string]::IsNullOrWhiteSpace($uri.UserInfo)) {
        $userInfoParts = $uri.UserInfo -split ":", 2
        $username = [System.Uri]::UnescapeDataString($userInfoParts[0])
        if ($userInfoParts.Count -gt 1) {
            $password = [System.Uri]::UnescapeDataString($userInfoParts[1])
        }
    }

    return [pscustomobject]@{
        Raw      = $ProxyUrl
        Scheme   = $uri.Scheme
        Host     = $uri.Host
        Port     = $uri.Port
        Username = $username
        Password = $password
        Server   = "$($uri.Scheme)://$($uri.Host):$($uri.Port)"
    }
}

function New-ProxyAuthExtension {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfilePath,

        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$ProxyConfiguration
    )

    if ([string]::IsNullOrWhiteSpace($ProxyConfiguration.Username) -and [string]::IsNullOrWhiteSpace($ProxyConfiguration.Password)) {
        return $null
    }

    $extensionPath = Join-Path -Path $ProfilePath -ChildPath "_managed_proxy_auth_extension"
    if (-not (Test-Path -LiteralPath $extensionPath)) {
        New-Item -ItemType Directory -Path $extensionPath -Force | Out-Null
    }

    $manifest = [ordered]@{
        manifest_version = 3
        name             = "Managed Proxy Auth $ProfileName"
        version          = "1.0.0"
        permissions      = @(
            "webRequest",
            "webRequestAuthProvider"
        )
        host_permissions = @(
            "<all_urls>"
        )
        background       = @{
            service_worker = "service-worker.js"
        }
    }

    $proxyConfigJson = (
        [ordered]@{
            host     = $ProxyConfiguration.Host
            port     = $ProxyConfiguration.Port
            username = $ProxyConfiguration.Username
            password = $ProxyConfiguration.Password
        } | ConvertTo-Json -Compress
    )

    $serviceWorker = @"
const proxyConfig = $proxyConfigJson;
const authAttempts = new Map();

function clearAttempt(details) {
  authAttempts.delete(details.requestId);
}

chrome.webRequest.onAuthRequired.addListener(
  (details) => {
    if (!details.isProxy) {
      return;
    }

    if (details.challenger.host !== proxyConfig.host || details.challenger.port !== proxyConfig.port) {
      return;
    }

    const priorAttempts = authAttempts.get(details.requestId) ?? 0;
    if (priorAttempts >= 1) {
      authAttempts.delete(details.requestId);
      return { cancel: true };
    }

    authAttempts.set(details.requestId, priorAttempts + 1);
    return {
      authCredentials: {
        username: proxyConfig.username,
        password: proxyConfig.password,
      },
    };
  },
  { urls: ['<all_urls>'] },
  ['blocking']
);

chrome.webRequest.onCompleted.addListener(clearAttempt, { urls: ['<all_urls>'] });
chrome.webRequest.onErrorOccurred.addListener(clearAttempt, { urls: ['<all_urls>'] });
"@

    Set-Content -LiteralPath (Join-Path -Path $extensionPath -ChildPath "manifest.json") -Value ($manifest | ConvertTo-Json -Depth 5) -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $extensionPath -ChildPath "service-worker.js") -Value $serviceWorker -Encoding UTF8

    return $extensionPath
}

function Find-ChromeExecutable {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$PreferredPath
    )

    $candidatePaths = New-Object System.Collections.Generic.List[string]

    $resolvedPreferredPath = Resolve-ScriptRelativePath -Path $PreferredPath
    if (-not [string]::IsNullOrWhiteSpace($resolvedPreferredPath)) {
        $candidatePaths.Add($resolvedPreferredPath)
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidatePaths.Add((Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"))
    }

    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $candidatePaths.Add((Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"))
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LocalAppData)) {
        $candidatePaths.Add((Join-Path $env:LocalAppData "Google\Chrome\Application\chrome.exe"))
    }

    foreach ($candidatePath in $candidatePaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidatePath) -and (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            return $candidatePath
        }
    }

    throw "Could not find chrome.exe. Set CHROME_PATH in .env or pass -ChromePath."
}

try {
    $dotEnvValues = Import-DotEnvFile -Path $EnvPath
    $countInput = $null
    if ($PSBoundParameters.ContainsKey("Count")) {
        $countInput = $Count
    }
    $profileRangeInput = $null
    if ($PSBoundParameters.ContainsKey("ProfileRange")) {
        $profileRangeInput = $ProfileRange
    }

    $BaseName = Get-EffectiveValue -PrimaryValue $BaseName -FallbackValue $dotEnvValues["CHROME_PROFILE_BASE_NAME"]
    $ProfileRoot = Get-EffectiveValue -PrimaryValue $ProfileRoot -FallbackValue $dotEnvValues["CHROME_PROFILE_ROOT"]
    $ChromePath = Get-EffectiveValue -PrimaryValue $ChromePath -FallbackValue $dotEnvValues["CHROME_PATH"]
    $ProxyFile = Get-EffectiveValue -PrimaryValue $ProxyFile -FallbackValue $dotEnvValues["CHROME_PROXY_FILE"]
    $CurrentProxy = Get-EffectiveValue -PrimaryValue $CurrentProxy -FallbackValue $dotEnvValues["CURRENT_PROXY"]
    $rangeFallbackValue = $dotEnvValues["CHROME_PROFILE_RANGE"]
    $countFallbackValue = $dotEnvValues["CHROME_PROFILE_COUNT"]

    if ($null -eq (Get-TrimmedString -Value $rangeFallbackValue) -and (Test-IsProfileRangeValue -Value $countFallbackValue)) {
        $rangeFallbackValue = $countFallbackValue
        $countFallbackValue = $null
    }

    $proxyConfigurations = @(
        Get-ProxyListFromFile -Path $ProxyFile |
        ForEach-Object { ConvertTo-ProxyConfiguration -ProxyUrl $_ }
    )
    $currentProxyIndex = Get-NonNegativeInt -Value $CurrentProxy -Name "CURRENT_PROXY"
    $selectedProxyConfiguration = $null
    if ($null -ne $currentProxyIndex) {
        if ($proxyConfigurations.Count -lt 1) {
            throw "CURRENT_PROXY is set but no proxy list is available. Set CHROME_PROXY_FILE first."
        }
        if ($currentProxyIndex -ge $proxyConfigurations.Count) {
            throw "CURRENT_PROXY must be between 0 and $($proxyConfigurations.Count - 1) for the configured proxy file."
        }
        $selectedProxyConfiguration = $proxyConfigurations[$currentProxyIndex]
    }

    $Count = Get-EffectiveInt -PrimaryValue $countInput -FallbackValue $countFallbackValue
    if (
        -not (Test-IsProfileRangeValue -Value $profileRangeInput) -and
        -not (Test-IsProfileRangeValue -Value $rangeFallbackValue) -and
        $Count -lt 1 -and
        $proxyConfigurations.Count -gt 0 -and
        $null -eq $selectedProxyConfiguration
    ) {
        $Count = $proxyConfigurations.Count
    }
    $profileNumberRange = Resolve-ProfileNumberRange -PrimaryValue $profileRangeInput -FallbackValue $rangeFallbackValue -FallbackCount $Count
    $Urls = Get-EffectiveUrlList -PrimaryUrls $Urls -FallbackUrls $dotEnvValues["CHROME_START_URLS"]

    if ([string]::IsNullOrWhiteSpace($BaseName)) {
        throw "Missing CHROME_PROFILE_BASE_NAME. Set it in .env or pass -BaseName."
    }

    if ([string]::IsNullOrWhiteSpace($ProfileRoot)) {
        $ProfileRoot = Resolve-ScriptRelativePath -Path "chrome-profiles"
    }
    else {
        $ProfileRoot = Resolve-ScriptRelativePath -Path $ProfileRoot
    }

    $ChromePath = Find-ChromeExecutable -PreferredPath $ChromePath

    if (-not (Test-Path -LiteralPath $ProfileRoot)) {
        New-Item -ItemType Directory -Path $ProfileRoot -Force | Out-Null
    }

    if ($proxyConfigurations.Count -gt 0 -and $null -eq $selectedProxyConfiguration -and $proxyConfigurations.Count -ne $profileNumberRange.Count) {
        throw "Proxy file contains $($proxyConfigurations.Count) proxies, but the profile selection resolves to $($profileNumberRange.Count) profiles. Make those counts match."
    }

    $results = New-Object System.Collections.Generic.List[object]

    for ($index = $profileNumberRange.Start; $index -le $profileNumberRange.End; $index++) {
        $profileName = "$BaseName$index"
        $profilePath = Join-Path -Path $ProfileRoot -ChildPath $profileName

        if (-not (Test-Path -LiteralPath $profilePath)) {
            New-Item -ItemType Directory -Path $profilePath -Force | Out-Null
        }

        $arguments = @(
            "--user-data-dir=$profilePath",
            "--new-window"
        )

        $proxyServer = $null
        if ($null -ne $selectedProxyConfiguration) {
            $arguments += "--proxy-server=$($selectedProxyConfiguration.Server)"
            $proxyServer = "proxy[$currentProxyIndex] $($selectedProxyConfiguration.Server)"
        }
        elseif ($proxyConfigurations.Count -gt 0) {
            $proxyConfiguration = $proxyConfigurations[$index - $profileNumberRange.Start]
            $proxyExtensionPath = New-ProxyAuthExtension -ProfilePath $profilePath -ProfileName $profileName -ProxyConfiguration $proxyConfiguration
            $arguments += "--proxy-server=$($proxyConfiguration.Server)"
            if (-not [string]::IsNullOrWhiteSpace($proxyExtensionPath)) {
                $arguments += "--load-extension=$proxyExtensionPath"
            }
            $proxyServer = $proxyConfiguration.Server
        }

        $arguments += $Urls

        Start-Process -FilePath $ChromePath -ArgumentList $arguments | Out-Null

        $results.Add([pscustomobject]@{
            profileName   = $profileName
            profileNumber = $index
            profilePath   = $profilePath
            chromePath    = $ChromePath
            proxyServer   = $proxyServer
            urls          = $Urls
        })
    }

    $results
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
