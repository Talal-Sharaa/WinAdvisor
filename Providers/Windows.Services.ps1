<#
    Providers/Windows.Services.ps1 - Windows services, advisory only.

    This provider reports and classifies. It proposes no service change, and that is a
    deliberate product decision rather than an unfinished feature.

    Mass service disabling is the single most common piece of Windows optimisation
    folklore, and the reason it persists is that the damage is delayed and hard to
    attribute: printing stops working a week later, a VPN fails to connect next month,
    Windows Update quietly stops. A service change is only defensible when the service is
    positively identified, its purpose is understood, the software or hardware that needs
    it is known to be absent, the benefit is concrete and the downside is documented.

    Config/policies.json carries a ServiceRecommendations list for curated entries meeting
    that bar. It ships empty. The execution engine implements and tests the service
    operation kind with full rollback, so an entry added there executes safely; but no
    entry ships, because none has met the bar.
#>

Register-WaProvider -Name 'Windows.Services' -Order 40 `
    -Title 'Windows services' `
    -Category 'Windows' `
    -Description 'Reports automatic-start services and classifies them. Proposes no changes: the shipped policy contains no curated service recommendations.' `
    -AdvisoryOnly $true `
    -Reference 'https://learn.microsoft.com/en-us/windows/win32/services/services' `
    -TestAvailable {
        param($Session)
        New-WaProviderAvailability -Available $true
    } `
    -GetInventory {
        param($Session)
        $services = @()
        try {
            $services = @(Get-WaCimData -ClassName 'Win32_Service' -Property @('Name', 'DisplayName', 'State', 'StartMode', 'PathName', 'Description'))
        } catch {
            return @()
        }

        $policy = $Session.Config.Policy
        @(foreach ($service in $services) {
            $name = [string](Get-WaProperty -Object $service -Name 'Name')
            $protected = Test-WaProtectedService -Name $name -Policy $policy
            New-WaInstalledComponent -Name $name -Category 'Service' `
                -Vendor '' -DetectionMethod 'Win32_Service' `
                -Note ('{0} | start {1} | state {2}{3}' -f
                    (Get-WaProperty -Object $service -Name 'DisplayName'),
                    (Get-WaProperty -Object $service -Name 'StartMode'),
                    (Get-WaProperty -Object $service -Name 'State'),
                    $(if ($protected) { ' | protected' } else { '' }))
        })
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $services = @()
        try {
            $services = @(Get-WaCimData -ClassName 'Win32_Service' -Property @('Name', 'DisplayName', 'State', 'StartMode'))
        } catch {
            return @()
        }

        $policy = $Session.Config.Policy
        $automatic = @($services | Where-Object { [string](Get-WaProperty -Object $_ -Name 'StartMode') -eq 'Auto' })
        $running   = @($automatic | Where-Object { [string](Get-WaProperty -Object $_ -Name 'State') -eq 'Running' })
        $protected = @($automatic | Where-Object { Test-WaProtectedService -Name ([string](Get-WaProperty -Object $_ -Name 'Name')) -Policy $policy })

        @(New-WaFinding -Id 'windows.services.inventory' `
            -Title 'Service configuration' -Category 'Windows services' -Provider 'Windows.Services' `
            -Description ('{0} service(s) are set to start automatically and {1} are running. WinAdvisor proposes no service changes.' -f $automatic.Count, $running.Count) `
            -Evidence @(
                New-WaEvidence -Source 'Win32_Service' -Method 'CIM enumeration' `
                    -Statement ('{0} automatic-start service(s), {1} currently running.' -f $automatic.Count, $running.Count) -Value $automatic.Count -Unit 'services'
                New-WaEvidence -Source 'Config/policies.json' -Method 'Policy inspection' `
                    -Statement ('{0} of them are on the never-modify list (security, endpoint protection, device management and core platform services).' -f $protected.Count) -Value $protected.Count -Unit 'services'
                New-WaEvidence -Source 'Config/policies.json' -Method 'Policy inspection' `
                    -Statement ('The curated ServiceRecommendations list contains {0} entries, so no service change is proposed.' -f @($policy.ServiceRecommendations).Count) -Measured $true
            ) `
            -CurrentImpact 'Automatic services consume memory and extend boot, but which ones matter is entirely machine-specific.' `
            -Confidence 'HIGH' -Disposition 'Informational' `
            -Warnings @(
                'Disabling services from a generic list is how printing, VPN, Bluetooth and Windows Update quietly stop working weeks later.'
                'If you do want to change one, identify it by name first, confirm what depends on it, and use services.msc so Windows records the change in the usual place.'
            ))
    } | Out-Null
