<#
.VERSION
1.0.0

.SYNOPSIS
Creates a service principle for use by an AKS cluster and creates the core resources deployment.
The secret password for the service principal is stored in the KeyVault that is created.

.PREREQUISITE
1. An Azure Active Directory tenant.

.PARAMETER SPName
Display name for the application object in AAD.

.PARAMETER IdentifierUri
Unique identifer for the application in Uri format.

.PARAMETER resourceGroup
The resource group to deploy core resources into.

.PARAMETER region
The region in which to deploy the core resources.


.EXAMPLE
. .\CreateSP.ps1 -SPName 'My AKS SP' -IdentifierUri 'https://myakssp' -resourceGroup 'Core' -region 'WestEurope'

Create service principal with the display name 'My AKS SP' and deploy resources into West Europe region.
#>

param (
    [Parameter(Mandatory=$true)]
    [String]
	$SPName,

    [Parameter(Mandatory=$true)]
    [String]
	$IdentifierUri,

    [Parameter(Mandatory=$true)]
    [String]
	$resourceGroup,

    [Parameter(Mandatory=$true)]
    [String]
	$region
)

$app = Get-AzADApplication -DisplayName $SPName

if ($null -eq $app)
{
    $app = New-AzADApplication `
        -DisplayName $SPName `
        -IdentifierUris @($IdentifierUri)
}

$sp = Get-AzADServicePrincipal -ApplicationId $app.ApplicationId

if($null -eq $sp)
{
    $sp = New-AzADServicePrincipal -ApplicationId $app.ApplicationId -SkipAssignment
    $pwd = $sp.Secret
}
else {
    $spc = New-AzADServicePrincipalCredential `
        -ObjectId $sp.Id `
        -StartDate $([DateTime]::Today) `
        -EndDate $([DateTime]::Today.AddYears(2))
    $pwd = $spc.Secret
}

$rg = Get-AzResourceGroup -Name $resourceGroup -ErrorAction SilentlyContinue

if ($null -ne $rg)
{
    if ($rg.Location -ne $region)
    {
        Write-Error -Message "Resource Group exists but is in region $($rg.Location), not $region"
        Exit 1
    }
}
else {
    $rg = New-AzResourceGroup -Name $resourceGroup -Location $region
}

$templateFile = Join-Path -Path $PSScriptRoot -ChildPath '.\core.json'
$settingsFile = Join-Path -Path $PSScriptRoot -ChildPath '.\core.params.json'

# Get the id of the currently logged in Azure user to make admin on the KeyVault
$meObjId = (Get-AzADUser -UserPrincipalName ((Get-AzContext).Account.Id)).Id

# Now deploy
$rgd = New-AzResourceGroupDeployment `
    -ResourceGroupName $resourceGroup `
    -Name "Core-$([DateTime]::Now.ToString('yymmddhhmm'))" `
    -TemplateFile $templateFile `
    -TemplateParameterFile $settingsFile `
    -keyVaultUser $meObjId `
    -servicePrincipalObjectId $sp.Id `
    -servicePrincipalClientSecret $pwd
