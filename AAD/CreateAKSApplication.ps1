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
        -Headers @{Authorization = $token.AccessToken}

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


$serverApp = @{
    displayName            = $ClusterAppName
    groupMembershipClaims  = "All"
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

Write-Verbose "Query for application with display name `"$ClusterAppName`""

$apps = GraphApiGet "applications?`$filter=displayName eq '$ClusterAppName'"

$app = $apps.value[0]

# Application already exists, update it to ensure the correct settings.
if ($null -ne $app) {
    Write-Verbose "Application `"$($app.displayName)`" already exists. AppId: $($app.appId)"
    Write-Verbose "Updating application with required settings"

    $resp = GraphApiUpdate "applications/$($app.objectId)" $serverApp
}
else
{ # Application does not exist, create a new one.
    Write-Verbose "Creating new application `"$($serverApp.displayName)`" ..."

    $app = GraphApiPost "applications" $serverApp

    # Set ownership link so that the app appears in "My Applications"
    GraphApiPost "applications/$($app.objectId)/`$links/owners" `
        @{ url="$resourceUrl/$($token.TenantId)/directoryObjects/$($token.UserInfo.UniqueId)" }

    Write-Verbose "New application created. AppId: $($app.appId)"
}

Write-Verbose "Query for service principal in ths tenant"

$svcPrincipals = GraphApiGet "servicePrincipals?`$filter=appId eq '$($app.appId)'"

$sp = $svcPrincipals.value[0]

if ($null -eq $sp) {
    Write-Verbose "Creating Service Principal"
    $requestBody = @{ appId = $app.appId } | ConvertTo-Json -Depth 10 -Compress

    $sp = GraphApiPost "servicePrincipals" @{ appId = $app.appId }
    Write-Verbose "New Service Principal (object id: $($sp.objectId)"
}
else {
    Write-Verbose "Service Principal already exists (object id: $($sp.objectId)"
}

# Now look up the service principals for "Microsoft Graph" and "Azure Active Directory"
# These are needed to create the role assignments.

$resp = GraphApiGet "servicePrincipals?`$filter=appId eq '$aadAppId'"

$aadSP = $resp.value[0]

$resp = GraphApiGet "servicePrincipals?`$filter=appId eq '$graphAppId'"

$graphSP = $resp.value[0]

# Check whether the permission grant and role assignments exist before trying to create them.

$permGrant = (GraphApiGet "oauth2PermissionGrants?`$filter=clientId eq '$($sp.objectId)' and resourceId eq '$($aadSP.objectId)'").value[0]

$oauth2PermissionGrants = @{
    clientId    = $sp.objectId
    consentType = "AllPrincipals"
    resourceId  = $aadSP.objectId
    scope       = "User.Read"
    expiryTime  = ([datetime]::Today.AddYears(2).ToString("yyyy-MM-ddTHH:mm:ss.fffffff"))
}

if ($null -ne $permGrant)
{
    Write-Verbose "Updating oauth2 permission grants for AAD."
    GraphApiUpdate "oauth2PermissionGrants/$($permGrant.objectId)" @{
        scope = "User.Read"
        expiryTime = [datetime]::Today.AddYears(2).ToString("O")
    }
}
else {
    $perm = GraphApiPost "oauth2PermissionGrants" $oauth2PermissionGrants
}

$permGrant = (GraphApiGet "oauth2PermissionGrants?`$filter=clientId eq '$($sp.objectId)' and resourceId eq '$($graphSP.objectId)'").value[0]

if ($null -ne $permGrant)
{
    Write-Verbose "Updating oauth2 permission grants Graph API."
    GraphApiUpdate "oauth2PermissionGrants/$($permGrant.objectId)" @{
        scope = "User.Read Directory.Read.All"
        expiryTime = [datetime]::Today.AddYears(2).ToString("O")
    }
}
else {
    $oauth2PermissionGrants.resourceId = $graphSP.objectId
    $oauth2PermissionGrants.scope = "User.Read Directory.Read.All"
    
    $perm = GraphApiPost "oauth2PermissionGrants" $oauth2PermissionGrants
}

(Invoke-WebRequest -Uri (BuildUrl "servicePrincipals/$($sp.objectId)/appRoleAssignments") `
-Headers @{Authorization = $token.AccessToken}).Content

# Check whether the app role assignment exists.
# Why is this not working? The same request in graph explorer returns results
$ra = GraphApiGet "servicePrincipals/$($sp.objectId)/appRoleAssignments"

$ra = $ra.value | Where-Object id -eq '7ab1d382-f21e-4acd-a863-ba3e13f7da61' | Select-Object -First 1

$roleAssignment = @{
    id          = '7ab1d382-f21e-4acd-a863-ba3e13f7da61'
    principalId = $sp.objectId
    resourceId  = $graphSP.objectId
}

$perm = GraphApiPost "servicePrincipals/$($sp.objectId)/appRoleAssignments" $roleAssignment

# Look up the guid created for the "user_impersonation" permission in the server app.
$permissonId = ($app.oauth2Permissions | ? value -eq 'user_impersonation').id

# Now create the AKS client application
$clientApp = @{
    displayName            = $ClientAppName
    requiredResourceAccess = @( @{
            resourceAppId  = $app.appId
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

# Does one exist already with the same display name?
$cliApp = (GraphApiGet "applications?`$filter=displayName eq '$ClientAppName'").value[0]

# Application already exists, update it to ensure the correct settings.
if ($null -ne $cliApp) {
    Write-Verbose "Application `"$($cliApp.displayName)`" already exists. AppId: $($cliApp.appId)"
    Write-Verbose "Updating application with required settings"

    $resp = GraphApiUpdate "applications/$($cliApp.objectId)" $clientApp
}
else
{ # Application does not exist, create a new one.
    Write-Verbose "Creating new application `"$($clientApp.displayName)`" ..."

    $cliApp = GraphApiPost "applications" $clientApp

    # Set ownership link so that the app appears in "My Applications"
    GraphApiPost "applications/$($cliApp.objectId)/`$links/owners" `
        @{ url="$resourceUrl/$($token.TenantId)/directoryObjects/$($token.UserInfo.UniqueId)" }

    Write-Verbose "New application created. AppId: $($cliApp.appId)"
}

# Create the service principal for the client app
$cliSp = (GraphApiGet "servicePrincipals?`$filter=appId eq '$($cliApp.appId)'").value[0]

if ($null -eq $cliSp) {
    Write-Verbose "Creating Service Principal"
    $cliSp = GraphApiPost "servicePrincipals" @{ appId = $cliApp.appId }
    Write-Verbose "New Service Principal (object id: $($cliSp.objectId)"
}
else {
    Write-Verbose "Service Principal already exists (object id: $($cliSp.objectId)"
}

$permGrant = (GraphApiGet "oauth2PermissionGrants?`$filter=clientId eq '$($cliSp.objectId)' and resourceId eq '$($aadSP.objectId)'").value[0]

$oauth2PermissionGrants = @{
    clientId    = $cliSp.objectId
    consentType = "AllPrincipals"
    resourceId  = $aadSP.objectId
    scope       = "User.Read"
    expiryTime  = ([datetime]::Today.AddYears(2).ToString("O"))
}

if ($null -ne $permGrant)
{
    Write-Verbose "Updating oauth2 permission grants for AAD."
    GraphApiUpdate "oauth2PermissionGrants/$($permGrant.objectId)" @{
        scope = "User.Read"
        expiryTime = [datetime]::Today.AddYears(2).ToString("O")
    }
}
else {
    $perm = GraphApiPost "oauth2PermissionGrants" $oauth2PermissionGrants
}

$permGrant = (GraphApiGet "oauth2PermissionGrants?`$filter=clientId eq '$($cliSp.objectId)' and resourceId eq '$($sp.objectId)'").value[0]

if ($null -ne $permGrant)
{
    Write-Verbose "Updating oauth2 permission grants Graph API."
    GraphApiUpdate "oauth2PermissionGrants/$($permGrant.objectId)" @{
        scope = "user_impersonation"
        expiryTime = [datetime]::Today.AddYears(2).ToString("O")
    }
}
else {
    $oauth2PermissionGrants.resourceId = $sp.objectId
    $oauth2PermissionGrants.scope = "user_impersonation"
    
    $perm = GraphApiPost "oauth2PermissionGrants" $oauth2PermissionGrants
}


return New-Object -TypeName PSObject -Property @{
    aadTenant      = $token.TenantId
    aadClientAppId = $cliApp.appId
    aadAppId       = $app.appId
}