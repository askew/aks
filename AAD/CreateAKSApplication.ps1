param (

    [Parameter(Mandatory = $true)]
    [String]
    $TenantId,

    [Parameter(Mandatory = $true)]
    [String]
    $ClusterAppName,

    [Parameter(Mandatory = $true)]
    [String]
    $ClientAppName

)

# Use the common client id for Azure PowerShell
$clientId = '1950a258-227b-4e31-a9cf-717495945fc2'

# Load in assembly for ADAL.
# This downloaded from https://www.nuget.org/packages/Microsoft.IdentityModel.Clients.ActiveDirectory/
Add-Type -Path (Join-Path $PSScriptRoot 'Microsoft.IdentityModel.Clients.ActiveDirectory.dll')

$resourceUrl = 'https://graph.windows.net'
$authString = 'https://login.microsoftonline.com/' + $TenantId
$apiver = '1.6'
$graphAppId = '00000003-0000-0000-c000-000000000000'
$aadAppId = '00000002-0000-0000-c000-000000000000'

# Auth context object
$authenticationContext = New-Object Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext -ArgumentList $authString, $false

# Try and get token from cache (if script has been run more than once)
$token = ($authenticationContext.AcquireTokenSilentAsync($resourceUrl, $clientId)).Result

# Otherwise authenticate using device code flow
if ($null -eq $token) {
    $devcode = ($authenticationContext.AcquireDeviceCodeAsync($resourceUrl, $clientId)).Result

    Write-Host $devcode.Message

    $token = ($authenticationContext.AcquireTokenByDeviceCodeAsync($devcode)).Result
}

Write-Verbose "Signed in as $($token.UserInfo.GivenName) $($token.UserInfo.FamilyName) ($($token.UserInfo.DisplayableId))"

function BuildUrl([String]$query) {
    $uri = New-Object -TypeName Uri -ArgumentList "$resourceUrl/$($token.TenantId)/$query"
    $urib = New-Object -TypeName UriBuilder -ArgumentList $uri
    if ($null -ne $urib.Query -and $urib.Query.Length -gt 1) {
        $urib.Query = $urib.Query.Substring(1) + "&api-version=$apiver"
    }
    else {
        $urib.Query = "api-version=$apiver"
    }
    return $urib.Uri
}

function GraphApiGet([String]$query) {
    $uri = BuildUrl $query

    $resp = Invoke-RestMethod -Uri $uri `
        -UseBasicParsing -Method Get `
        -Headers @{Authorization = "Bearer $($token.AccessToken)"; Accept = 'application/json'; 'Accept-Encoding'='gzip, deflate, br'}

    return $resp
}

function GraphApiPost([String]$query, $payload) {
    $uri = BuildUrl $query

    $requestBody = ConvertTo-Json -InputObject $payload -Depth 10 -Compress

    $resp = Invoke-RestMethod -Uri $uri `
        -UseBasicParsing -Method Post `
        -Body $requestBody `
        -ContentType 'application/json' `
        -Headers @{Authorization = $token.AccessToken}

    return $resp
}

function GraphApiUpdate([String]$query, $payload) {
    $uri = BuildUrl $query

    $requestBody = ConvertTo-Json -InputObject $payload -Depth 10 -Compress

    $resp = Invoke-RestMethod -Uri $uri `
        -UseBasicParsing -Method Patch `
        -Body $requestBody `
        -ContentType 'application/json' `
        -Headers @{Authorization = $token.AccessToken}

    return $resp
}

function CreateApplicationWithSP([Hashtable] $appSettings)
{
    $apps = GraphApiGet "applications?`$filter=displayName eq '$($appSettings.displayName)'"

    $app = $apps.value[0]

    # Application already exists, update it to ensure the correct settings.
    if ($null -ne $app) {
        Write-Verbose "Application `"$($app.displayName)`" already exists. AppId: $($app.appId)"
        Write-Verbose "Updating application with required settings"

        $resp = GraphApiUpdate "applications/$($app.objectId)" $appSettings
    }
    else
    { # Application does not exist, create a new one.
        Write-Verbose "Creating new application `"$($appSettings.displayName)`" ..."

        $app = GraphApiPost "applications" $appSettings

        # Set ownership link so that the app appears in "My Applications"
        GraphApiPost "applications/$($app.objectId)/`$links/owners" `
            @{ url="$resourceUrl/$($token.TenantId)/directoryObjects/$($token.UserInfo.UniqueId)" }

        Write-Verbose "New application created. AppId: $($app.appId)"
    }

    $sp = (GraphApiGet "servicePrincipals?`$filter=appId eq '$($app.appId)'").value[0]

    if ($null -eq $sp) {
        Write-Verbose "Creating Service Principal"
        $sp = GraphApiPost "servicePrincipals" @{ appId = $app.appId }
        Write-Verbose "New Service Principal (object id: $($sp.objectId)"
    }
    else {
        Write-Verbose "Service Principal already exists (object id: $($sp.objectId)"
    }

    return New-Object PSObject @{ app = $app; sp = $sp }
}

# Get the default domain name for the tenant.
$domainName = ((GraphApiGet 'domains').value | Where-Object isDefault | Select-Object -First 1).name

$serverAppSettings = @{
    displayName            = $ClusterAppName
    identifierUris         = @(
        (New-Object Uri "https://$domainName/$ClusterAppName").AbsoluteUri
        )
    groupMembershipClaims  = "All"
    replyUrls = @(
        (New-Object Uri "https://$domainName/$ClusterAppName").AbsoluteUri
        )
    requiredResourceAccess = @( @{
            resourceAppId  = $graphAppId
            resourceAccess = @( @{
                    id   = '7ab1d382-f21e-4acd-a863-ba3e13f7da61'
                    type = 'Role'
                }, @{
                    id   = 'e1fe6dd8-ba31-4d61-89e7-88639da4683d'
                    type = 'Scope'
                }, @{
                    id   = '06da0dbc-49e2-44d2-8312-53f166ab848a'
                    type = 'Scope'
                } )
        }, @{
            resourceAppId  = $aadAppId
            resourceAccess = @( @{
                    id   = '311a71cc-e848-46a1-bdf8-97ff7156d8e6'
                    type = 'Scope'
                } )
        } )
}

$server = CreateApplicationWithSP $serverAppSettings

# Now look up the service principals for "Microsoft Graph" and "Azure Active Directory"
# These are needed to create the role assignments.

$aadSP = (GraphApiGet "servicePrincipals?`$filter=appId eq '$aadAppId'").value[0]

$graphSP = (GraphApiGet "servicePrincipals?`$filter=appId eq '$graphAppId'").value[0]

function AddPermissionGrant ([string]$clientId, [string]$resourceId, [array]$scopes)
{
    Write-Host "`$clientId = $clientId, `$resourceId = $resourceId, `$scopes = `"$($scopes -join ' ')`"" -ForegroundColor Yellow

    # Look up existing permission grant
    $permGrant = (GraphApiGet "oauth2PermissionGrants?`$filter=clientId eq '$clientId' and resourceId eq '$resourceId'").value[0]

    $oauth2PermissionGrants = @{
        clientId    = $clientId
        consentType = "AllPrincipals"
        resourceId  = $resourceId
        scope       = $scopes -join ' '
        expiryTime  = ([datetime]::Today.AddYears(2).ToString("O"))
    }

    # Check whether the permission grant and role assignments exist before trying to create them.
    if ($null -ne $permGrant)
    {
        Write-Verbose "Updating oauth2 permission grants."
        GraphApiUpdate "oauth2PermissionGrants/$($permGrant.objectId)" @{
            scope = $scopes -join ' '
            expiryTime = [datetime]::Today.AddYears(2).ToString("O")
        }
    }
    else {
        $perm = GraphApiPost "oauth2PermissionGrants" $oauth2PermissionGrants
    }

}

Write-Verbose "AAD Permission Grant ..."
AddPermissionGrant $server.sp.objectId $aadSP.objectId "User.Read"

Write-Verbose "Graph Permission Grant ..."
AddPermissionGrant $server.sp.objectId $graphSP.objectId @("User.Read", "Directory.Read.All")

# Check whether the app role assignment exists.
# Why is this not working? The same request in graph explorer returns results
$ra = GraphApiGet "servicePrincipals/$($server.sp.objectId)/appRoleAssignments"

Write-Verbose "Application `"$($server.app.displayName)`" has $($ra.value.count) role assignments."

$ra = $ra.value | Where-Object id -eq '7ab1d382-f21e-4acd-a863-ba3e13f7da61' | Select-Object -First 1

$roleAssignment = @{
    id          = '7ab1d382-f21e-4acd-a863-ba3e13f7da61'
    principalId = $server.sp.objectId
    resourceId  = $graphSP.objectId
}

$perm = GraphApiPost "servicePrincipals/$($server.sp.objectId)/appRoleAssignments" $roleAssignment

# Look up the guid created for the "user_impersonation" permission in the server app.
$permissonId = ($server.app.oauth2Permissions | Where-Object value -eq 'user_impersonation').id

# Now create the AKS client application
$clientAppSettings = @{
    displayName            = $ClientAppName
    publicClient = $true
    replyUrls = @( (New-Object Uri "https://$domainName/$ClientAppName").AbsoluteUri )
    requiredResourceAccess = @( @{
            resourceAppId  = $server.app.appId
            resourceAccess = @( @{
                    id   = $permissonId
                    type = 'Scope'
                } )
        }, @{
            resourceAppId  = $aadAppId
            resourceAccess = @( @{
                    id   = '311a71cc-e848-46a1-bdf8-97ff7156d8e6'
                    type = 'Scope'
                } )
        } )
}

$client = CreateApplicationWithSP $clientAppSettings

Write-Verbose "AAD Permission Grant ..."
AddPermissionGrant $client.sp.objectId $aadSP.objectId "User.Read"

Write-Verbose "AKS Server App Permission Grant ..."
AddPermissionGrant $client.sp.objectId $server.sp.objectId "user_impersonation"

return New-Object -TypeName PSObject -Property @{
    aadTenant      = $token.TenantId
    aadClientAppId = $client.app.appId
    aadAppId       = $server.app.appId
}

# SIG # Begin signature block
# MIIXrQYJKoZIhvcNAQcCoIIXnjCCF5oCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUVWXwY7GA5QJ/lSFD+yy+3N74
# fzGgghLgMIID7jCCA1egAwIBAgIQfpPr+3zGTlnqS5p31Ab8OzANBgkqhkiG9w0B
# AQUFADCBizELMAkGA1UEBhMCWkExFTATBgNVBAgTDFdlc3Rlcm4gQ2FwZTEUMBIG
# A1UEBxMLRHVyYmFudmlsbGUxDzANBgNVBAoTBlRoYXd0ZTEdMBsGA1UECxMUVGhh
# d3RlIENlcnRpZmljYXRpb24xHzAdBgNVBAMTFlRoYXd0ZSBUaW1lc3RhbXBpbmcg
# Q0EwHhcNMTIxMjIxMDAwMDAwWhcNMjAxMjMwMjM1OTU5WjBeMQswCQYDVQQGEwJV
# UzEdMBsGA1UEChMUU3ltYW50ZWMgQ29ycG9yYXRpb24xMDAuBgNVBAMTJ1N5bWFu
# dGVjIFRpbWUgU3RhbXBpbmcgU2VydmljZXMgQ0EgLSBHMjCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBALGss0lUS5ccEgrYJXmRIlcqb9y4JsRDc2vCvy5Q
# WvsUwnaOQwElQ7Sh4kX06Ld7w3TMIte0lAAC903tv7S3RCRrzV9FO9FEzkMScxeC
# i2m0K8uZHqxyGyZNcR+xMd37UWECU6aq9UksBXhFpS+JzueZ5/6M4lc/PcaS3Er4
# ezPkeQr78HWIQZz/xQNRmarXbJ+TaYdlKYOFwmAUxMjJOxTawIHwHw103pIiq8r3
# +3R8J+b3Sht/p8OeLa6K6qbmqicWfWH3mHERvOJQoUvlXfrlDqcsn6plINPYlujI
# fKVOSET/GeJEB5IL12iEgF1qeGRFzWBGflTBE3zFefHJwXECAwEAAaOB+jCB9zAd
# BgNVHQ4EFgQUX5r1blzMzHSa1N197z/b7EyALt0wMgYIKwYBBQUHAQEEJjAkMCIG
# CCsGAQUFBzABhhZodHRwOi8vb2NzcC50aGF3dGUuY29tMBIGA1UdEwEB/wQIMAYB
# Af8CAQAwPwYDVR0fBDgwNjA0oDKgMIYuaHR0cDovL2NybC50aGF3dGUuY29tL1Ro
# YXd0ZVRpbWVzdGFtcGluZ0NBLmNybDATBgNVHSUEDDAKBggrBgEFBQcDCDAOBgNV
# HQ8BAf8EBAMCAQYwKAYDVR0RBCEwH6QdMBsxGTAXBgNVBAMTEFRpbWVTdGFtcC0y
# MDQ4LTEwDQYJKoZIhvcNAQEFBQADgYEAAwmbj3nvf1kwqu9otfrjCR27T4IGXTdf
# plKfFo3qHJIJRG71betYfDDo+WmNI3MLEm9Hqa45EfgqsZuwGsOO61mWAK3ODE2y
# 0DGmCFwqevzieh1XTKhlGOl5QGIllm7HxzdqgyEIjkHq3dlXPx13SYcqFgZepjhq
# IhKjURmDfrYwggSjMIIDi6ADAgECAhAOz/Q4yP6/NW4E2GqYGxpQMA0GCSqGSIb3
# DQEBBQUAMF4xCzAJBgNVBAYTAlVTMR0wGwYDVQQKExRTeW1hbnRlYyBDb3Jwb3Jh
# dGlvbjEwMC4GA1UEAxMnU3ltYW50ZWMgVGltZSBTdGFtcGluZyBTZXJ2aWNlcyBD
# QSAtIEcyMB4XDTEyMTAxODAwMDAwMFoXDTIwMTIyOTIzNTk1OVowYjELMAkGA1UE
# BhMCVVMxHTAbBgNVBAoTFFN5bWFudGVjIENvcnBvcmF0aW9uMTQwMgYDVQQDEytT
# eW1hbnRlYyBUaW1lIFN0YW1waW5nIFNlcnZpY2VzIFNpZ25lciAtIEc0MIIBIjAN
# BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAomMLOUS4uyOnREm7Dv+h8GEKU5Ow
# mNutLA9KxW7/hjxTVQ8VzgQ/K/2plpbZvmF5C1vJTIZ25eBDSyKV7sIrQ8Gf2Gi0
# jkBP7oU4uRHFI/JkWPAVMm9OV6GuiKQC1yoezUvh3WPVF4kyW7BemVqonShQDhfu
# ltthO0VRHc8SVguSR/yrrvZmPUescHLnkudfzRC5xINklBm9JYDh6NIipdC6Anqh
# d5NbZcPuF3S8QYYq3AhMjJKMkS2ed0QfaNaodHfbDlsyi1aLM73ZY8hJnTrFxeoz
# C9Lxoxv0i77Zs1eLO94Ep3oisiSuLsdwxb5OgyYI+wu9qU+ZCOEQKHKqzQIDAQAB
# o4IBVzCCAVMwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAO
# BgNVHQ8BAf8EBAMCB4AwcwYIKwYBBQUHAQEEZzBlMCoGCCsGAQUFBzABhh5odHRw
# Oi8vdHMtb2NzcC53cy5zeW1hbnRlYy5jb20wNwYIKwYBBQUHMAKGK2h0dHA6Ly90
# cy1haWEud3Muc3ltYW50ZWMuY29tL3Rzcy1jYS1nMi5jZXIwPAYDVR0fBDUwMzAx
# oC+gLYYraHR0cDovL3RzLWNybC53cy5zeW1hbnRlYy5jb20vdHNzLWNhLWcyLmNy
# bDAoBgNVHREEITAfpB0wGzEZMBcGA1UEAxMQVGltZVN0YW1wLTIwNDgtMjAdBgNV
# HQ4EFgQURsZpow5KFB7VTNpSYxc/Xja8DeYwHwYDVR0jBBgwFoAUX5r1blzMzHSa
# 1N197z/b7EyALt0wDQYJKoZIhvcNAQEFBQADggEBAHg7tJEqAEzwj2IwN3ijhCcH
# bxiy3iXcoNSUA6qGTiWfmkADHN3O43nLIWgG2rYytG2/9CwmYzPkSWRtDebDZw73
# BaQ1bHyJFsbpst+y6d0gxnEPzZV03LZc3r03H0N45ni1zSgEIKOq8UvEiCmRDoDR
# EfzdXHZuT14ORUZBbg2w6jiasTraCXEQ/Bx5tIB7rGn0/Zy2DBYr8X9bCT2bW+IW
# yhOBbQAuOA2oKY8s4bL0WqkBrxWcLC9JG9siu8P+eJRRw4axgohd8D20UaF5Mysu
# e7ncIAkTcetqGVvP6KUwVyyJST+5z3/Jvz4iaGNTmr1pdKzFHTx/kuDDvBzYBHUw
# ggUPMIID96ADAgECAhAHDg49HRIAS0qASuPYWACfMA0GCSqGSIb3DQEBCwUAMHIx
# CzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3
# dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lDZXJ0IFNIQTIgQXNzdXJlZCBJ
# RCBDb2RlIFNpZ25pbmcgQ0EwHhcNMTgxMTA3MDAwMDAwWhcNMTkxMTA0MTIwMDAw
# WjBMMQswCQYDVQQGEwJHQjENMAsGA1UEBxMEQmF0aDEWMBQGA1UEChMNU3RlcGhl
# biBBc2tldzEWMBQGA1UEAxMNU3RlcGhlbiBBc2tldzCCASIwDQYJKoZIhvcNAQEB
# BQADggEPADCCAQoCggEBALxM4ss2nY/YJYqDKInuqEQZxF0ZUmR3m6RLA2QkrX3T
# i6hUaoTtwojcF0PyjmzK73I+CjDKLpfXFPSN2ixn7v+TL+HaXhxfGFYoCsePPFTu
# UAzzInC9JdSyOlw9fcS03zPgnq5nCTjZyIUhat0gaHgM7e9kwvj5BYCfJhLj05Ks
# 6cUfkvEhMphdwIhEg83i3Dr9x1VF+14Q3GofItvUBqjQNPdtW9cCzYs9tJ92n9F3
# vc5z4Qzrq5ZcVvze0x+GOA2fOv9kmXmdRhphSHqPx0E+EvcVl/IltyYADDSoGe/t
# vuWH9+/EOdeCGrIsdVPEdp9wmcYDsBmOYiMI9XwPQhUCAwEAAaOCAcUwggHBMB8G
# A1UdIwQYMBaAFFrEuXsqCqOl6nEDwGD5LfZldQ5YMB0GA1UdDgQWBBS9XKcbxbQ4
# A9IWcXjrJbE4XtmkWTAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUH
# AwMwdwYDVR0fBHAwbjA1oDOgMYYvaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL3No
# YTItYXNzdXJlZC1jcy1nMS5jcmwwNaAzoDGGL2h0dHA6Ly9jcmw0LmRpZ2ljZXJ0
# LmNvbS9zaGEyLWFzc3VyZWQtY3MtZzEuY3JsMEwGA1UdIARFMEMwNwYJYIZIAYb9
# bAMBMCowKAYIKwYBBQUHAgEWHGh0dHBzOi8vd3d3LmRpZ2ljZXJ0LmNvbS9DUFMw
# CAYGZ4EMAQQBMIGEBggrBgEFBQcBAQR4MHYwJAYIKwYBBQUHMAGGGGh0dHA6Ly9v
# Y3NwLmRpZ2ljZXJ0LmNvbTBOBggrBgEFBQcwAoZCaHR0cDovL2NhY2VydHMuZGln
# aWNlcnQuY29tL0RpZ2lDZXJ0U0hBMkFzc3VyZWRJRENvZGVTaWduaW5nQ0EuY3J0
# MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggEBALLTK4V1Mgx//5sksBRl
# 5ieQ4ZDH0apIOFnOd/ZlFLNrStrBV3JAv018YIkh6dX7yhAtUsKyMY+rqBMXohKq
# 9gi1k4v9+OGvYSDumK4ZU2MYQvRhHKnnDd6FWGhNxJLpzxihtzTfSdnL70umuWh8
# 5XVE2keXLb5BOJo1S5SNeLRvimrftvHugXVq9+uiYrJSM/9peiKbYmCmGYC1QdHf
# jlarCGWu3cNxF5V2GlrWU9L7BuC0O3iaY3A5/QsejkXzx9EPm+J5tcllCo70LjCf
# zq7A5YDUos6OAKtvY6QkhNjBYtiA40T9/qPYGp1XxuRfwJ2KlDa6qTGKvlzkB2mX
# AqYwggUwMIIEGKADAgECAhAECRgbX9W7ZnVTQ7VvlVAIMA0GCSqGSIb3DQEBCwUA
# MGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsT
# EHd3dy5kaWdpY2VydC5jb20xJDAiBgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQg
# Um9vdCBDQTAeFw0xMzEwMjIxMjAwMDBaFw0yODEwMjIxMjAwMDBaMHIxCzAJBgNV
# BAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdp
# Y2VydC5jb20xMTAvBgNVBAMTKERpZ2lDZXJ0IFNIQTIgQXNzdXJlZCBJRCBDb2Rl
# IFNpZ25pbmcgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQD407Mc
# fw4Rr2d3B9MLMUkZz9D7RZmxOttE9X/lqJ3bMtdx6nadBS63j/qSQ8Cl+YnUNxnX
# tqrwnIal2CWsDnkoOn7p0WfTxvspJ8fTeyOU5JEjlpB3gvmhhCNmElQzUHSxKCa7
# JGnCwlLyFGeKiUXULaGj6YgsIJWuHEqHCN8M9eJNYBi+qsSyrnAxZjNxPqxwoqvO
# f+l8y5Kh5TsxHM/q8grkV7tKtel05iv+bMt+dDk2DZDv5LVOpKnqagqrhPOsZ061
# xPeM0SAlI+sIZD5SlsHyDxL0xY4PwaLoLFH3c7y9hbFig3NBggfkOItqcyDQD2Rz
# PJ6fpjOp/RnfJZPRAgMBAAGjggHNMIIByTASBgNVHRMBAf8ECDAGAQH/AgEAMA4G
# A1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDAzB5BggrBgEFBQcBAQRt
# MGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBDBggrBgEF
# BQcwAoY3aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJl
# ZElEUm9vdENBLmNydDCBgQYDVR0fBHoweDA6oDigNoY0aHR0cDovL2NybDQuZGln
# aWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDA6oDigNoY0aHR0
# cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNy
# bDBPBgNVHSAESDBGMDgGCmCGSAGG/WwAAgQwKjAoBggrBgEFBQcCARYcaHR0cHM6
# Ly93d3cuZGlnaWNlcnQuY29tL0NQUzAKBghghkgBhv1sAzAdBgNVHQ4EFgQUWsS5
# eyoKo6XqcQPAYPkt9mV1DlgwHwYDVR0jBBgwFoAUReuir/SSy4IxLVGLp6chnfNt
# yA8wDQYJKoZIhvcNAQELBQADggEBAD7sDVoks/Mi0RXILHwlKXaoHV0cLToaxO8w
# Ydd+C2D9wz0PxK+L/e8q3yBVN7Dh9tGSdQ9RtG6ljlriXiSBThCk7j9xjmMOE0ut
# 119EefM2FAaK95xGTlz/kLEbBw6RFfu6r7VRwo0kriTGxycqoSkoGjpxKAI8LpGj
# wCUR4pwUR6F6aGivm6dcIFzZcbEMj7uo+MUSaJ/PQMtARKUT8OZkDCUIQjKyNook
# Av4vcn4c10lFluhZHen6dGRrsutmQ9qzsIzV6Q3d9gEgzpkxYz0IGhizgZtPxpMQ
# BvwHgfqL2vmCSfdibqFT+hKUGIUukpHqaGxEMrJmoecYpJpkUe8xggQ3MIIEMwIB
# ATCBhjByMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYD
# VQQLExB3d3cuZGlnaWNlcnQuY29tMTEwLwYDVQQDEyhEaWdpQ2VydCBTSEEyIEFz
# c3VyZWQgSUQgQ29kZSBTaWduaW5nIENBAhAHDg49HRIAS0qASuPYWACfMAkGBSsO
# AwIaBQCgeDAYBgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEM
# BgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMCMGCSqG
# SIb3DQEJBDEWBBSVPGOiMRip+yUf0rNpFwvbK5n4YDANBgkqhkiG9w0BAQEFAASC
# AQCzb5NXLC6raT05lXY9uCyChnC4Eg5JZktjeypB4Pyek2kwqLjyohmyC279A7rL
# 1qONIseHmOZfNbpS6lgYVtT7AT6YoGtCaaqsGmv2DyCTLUN6rcr5ugsY+DLpSOAC
# 9LZG+BsJAj5bRpvqb7aZnLhBBWGie0tLH2i+oybj7ydfD2RJCCrzskEMmrvvNbHU
# UwwPY4pdUZMpwyQoDY4M9dPj+WLOQFh0dVjug6Q5oS1IGGVE5B3XvsaIHUujdn5y
# pVpSqaHX+UjCcKSUa/8Nvp5oCE+ynYeGhOWGcyF6Mr7bm7VHZ608+bPMf+SoIM84
# uXbEel+7l1u9EFJ3kicWO+GroYICCzCCAgcGCSqGSIb3DQEJBjGCAfgwggH0AgEB
# MHIwXjELMAkGA1UEBhMCVVMxHTAbBgNVBAoTFFN5bWFudGVjIENvcnBvcmF0aW9u
# MTAwLgYDVQQDEydTeW1hbnRlYyBUaW1lIFN0YW1waW5nIFNlcnZpY2VzIENBIC0g
# RzICEA7P9DjI/r81bgTYapgbGlAwCQYFKw4DAhoFAKBdMBgGCSqGSIb3DQEJAzEL
# BgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTE5MDMwNDE2MTAwMlowIwYJKoZI
# hvcNAQkEMRYEFNQNStI9WeE8GJ0UNpTmYA4EScQCMA0GCSqGSIb3DQEBAQUABIIB
# AC7uTq6cW19fzAkxIwzOv93pjv+c4RY2X1TP5H4e3zVg1SrHy7zCAr+DKpnHkcXb
# X0z1w3KB66AgveZeDaDfzE85hixH5NNuX5PG6K8PIF+bHpalnunt99EUS2HNyqba
# Y7yG5fPPoqL9XQrTIfVxXIo0s09MsyFe0JTTK/pIuQAlx3wIZobQX1Qsoq1knzsq
# g7ojGhuSH2nXzgQ3vk9rdWwzRm0FC909n3PPKh8uOleBJxEPGMi57RodDadIWAWS
# PgKVHwt0ZDW5ug7I4sGpod/7TYnLeF9/hs9eo5E4MJroVmHn2rycILcpKTUQVTuP
# 2RH2NgDV5bu7bVrs3IQdUnk=
# SIG # End signature block
