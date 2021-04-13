# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

#requires -Version 7.0

using module PowerShellForGitHub
using namespace System.Management.Automation

class RepoNames: IValidateSetValuesGenerator {
    # NOTE: This is super over-engineered, but it was fun.
    static [string[]] $Values = "vscode-powershell", "PowerShellEditorServices"
    [String[]] GetValidValues() { return [RepoNames]::Values }
}

$ChangelogFile = "CHANGELOG.md"

<#
.SYNOPSIS
  Given a collection of PRs, generates a bulleted list.
#>
function Get-Bullets {
    param(
        [Parameter(Mandatory)]
        [ValidateSet([RepoNames])]
        [string]$RepositoryName,

        [Parameter(Mandatory, ValueFromPipeline)]
        [PSCustomObject[]]$PullRequests
    )
    begin {
        $SkipThanks = @(
            'andschwa'
            'daxian-dbw'
            'PaulHigin'
            'rjmholt'
            'SteveL-MSFT'
            'TylerLeonhardt'
        )

        $LabelEmoji = @{
            'Issue-Enhancement'         = '✨'
            'Issue-Bug'                 = '🐛'
            'Issue-Performance'         = '⚡️'
            'Area-Build & Release'      = '👷'
            'Area-Code Formatting'      = '💎'
            'Area-Configuration'        = '🔧'
            'Area-Debugging'            = '🔍'
            'Area-Documentation'        = '📖'
            'Area-Engine'               = '🚂'
            'Area-Folding'              = '📚'
            'Area-Integrated Console'   = '📟'
            'Area-IntelliSense'         = '🧠'
            'Area-Logging'              = '💭'
            'Area-Pester'               = '🐢'
            'Area-Script Analysis'      = '‍🕵️'
            'Area-Snippets'             = '✂️'
            'Area-Startup'              = '🛫'
            'Area-Symbols & References' = '🔗'
            'Area-Tasks'                = '✅'
            'Area-Test'                 = '🚨'
            'Area-Threading'            = '⏱️'
            'Area-UI'                   = '📺'
            'Area-Workspaces'           = '📁'
        }

        $CloseKeywords = @(
            'close'
            'closes'
            'closed'
            'fix'
            'fixes'
            'fixed'
            'resolve'
            'resolves'
            'resolved'
        )

        $IssueRegex = '(' + ($CloseKeywords -join '|') + ')\s+(?<repo>\D+)(?<number>\d+)'
    }

    process {
        $PullRequests | ForEach-Object {
            # Map all the labels to emoji (or use a default).
            # NOTE: Whitespacing here is weird.
            $emoji = if ($_.labels) {
                $LabelEmoji[$_.labels.LabelName] -join ""
            } else {
                '#️⃣ 🙏'
            }

            # Get a linked issue number if it exists (or use the PR).
            $link = if ($_.body -match $IssueRegex) {
                $number = $Matches.number
                $repo = $Matches.repo
                # Handle links to issues in both repos, in both shortcode and URLs.
                $name = [RepoNames]::Values | Where-Object { $repo -match $_ } | Select-Object -First 1
                "$($name ?? $RepositoryName) #$number"
            } else {
                "$RepositoryName #$($_.number)"
            }

            # Thank the contributor if they are not one of us.
            $thanks = if ($_.user.UserName -notin $SkipThanks) {
                "(Thanks @$($_.user.UserName)!)"
            }

            # Put the bullet point together.
            ("-", $emoji, "[$link]($($_.html_url))", "-", "$($_.title).", $thanks -join " ").Trim()
        }
    }
}

<#
.SYNOPSIS
  Gets the unpublished content from the changelog.
.DESCRIPTION
  This is used so that we can manually touch-up the automatically updated
  changelog, and then bring its contents into the extension's changelog or
  the GitHub release.
#>
function Get-NewChangelog {
    param(
        [Parameter(Mandatory)]
        [ValidateSet([RepoNames])]
        [string]$RepositoryName
    )
    $Repo = Get-GitHubRepository -OwnerName PowerShell -RepositoryName $RepositoryName
    $Release = $Repo | Get-GitHubRelease -Latest
    $Changelog = Get-Content -Path "$PSScriptRoot/../../$RepositoryName/$ChangelogFile"
    $Changelog.Where(
        { $_.StartsWith("##") }, "SkipUntil"
    ).Where(
        { $_.StartsWith("## $($Release.tag_name)") }, "Until"
    )
}

<#
.SYNOPSIS
  Updates the CHANGELOG file with PRs merged since the last release.
.DESCRIPTION
  Uses the local Git repositories but does not pull, so ensure HEAD is where
  you want it. Creates a new branch at release/$Version if not already
  checked out. Handles any merge option for PRs, but is a little slow as it
  queries all closed PRs.
#>
function Update-Changelog {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet([RepoNames])]
        [string]$RepositoryName,

        [Parameter(Mandatory)]
        [ValidateScript({ $_.StartsWith("v") })]
        [string]$Version
    )
    # NOTE: This a side effect neccesary for Git operations to work.
    Push-Location -Path "$PSScriptRoot/../../$RepositoryName"

    # Get the repo object, latest release, and commits since its tag.
    $Repo = Get-GitHubRepository -OwnerName PowerShell -RepositoryName $RepositoryName
    $Release = $Repo | Get-GitHubRelease -Latest
    $Commits = git rev-list "$($Release.tag_name)..."

    # NOTE: This is a slow API as it gets all closed PRs, and then filters.
    $Bullets = $Repo | Get-GitHubPullRequest -State Closed |
        Where-Object { $_.merge_commit_sha -in $Commits } |
        Where-Object { -not $_.user.UserName.EndsWith("[bot]") } |
        Where-Object { -not $_.title.StartsWith("[Ignore]") } |
        Get-Bullets -RepositoryName $RepositoryName

    $NewSection = switch ($RepositoryName) {
        "vscode-powershell" {
            @(
                "#### [vscode-powershell](https://github.com/PowerShell/vscode-powershell)`n"
                $Bullets
                ""
                "#### [PowerShellEditorServices](https://github.com/PowerShell/PowerShellEditorServices)`n"
                (Get-NewChangelog -RepositoryName "PowerShellEditorServices").Where({ $_.StartsWith("- ") }, "SkipUntil")
            )
        }
        "PowerShellEditorServices" {
            @($Bullets)
        }
    }

    $CurrentChangelog = Get-Content -Path $ChangelogFile

    @(
        $CurrentChangelog[0..1]
        "## $Version"
        "### $([datetime]::Now.ToString('dddd, MMMM dd, yyyy'))`n"
        $NewSection
        $CurrentChangelog[2..$CurrentChangelog.Length]
    ) | Set-Content -Encoding utf8NoBOM -Path $ChangelogFile

    if ($PSCmdlet.ShouldProcess("$RepositoryName/$ChangelogFile", "git")) {
        $branch = git branch --show-current
        if ($branch -ne "release/$Version") {
            git checkout -b "release/$Version"
        }
        git add $ChangelogFile
        git commit -m "Update CHANGELOG for $Version"
    }

    Pop-Location
}

<#
.SYNOPSIS
  Updates version in repository.
.DESCRIPTION
  Note that our Git tags and changelog prefix all versions with `v`.

  PowerShellEditorServices: version is `x.y.z-preview.d`

  - PowerShellEditorServices.psd1:
    - `ModuleVersion` variable with `'x.y.z'` string, no pre-release info
  - PowerShellEditorServices.Common.props:
    - `VersionPrefix` field with `x.y.z`
    - `VersionSuffix` field with pre-release portion excluding hyphen

  vscode-powershell: version is `yyyy.mm.x-preview`

  - package.json:
    - `version` field with `"x.y.z"` and no prefix or suffix
    - `preview` field set to `true` or `false` if version is a preview
    - `name` field has `-preview` appended similarly
    - `displayName` field has ` Preview` appended similarly
    - `description` field has `(Preview) ` prepended similarly
#>
function Update-Version {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet([RepoNames])]
        [string]$RepositoryName
    )
    # NOTE: This a side effect neccesary for Git operations to work.
    Push-Location -Path "$PSScriptRoot/../../$RepositoryName"

    $Version = Get-Version -RepositoryName $RepositoryName
    $v = "$($Version.Major).$($Version.Minor).$($Version.Patch)"
    # TODO: Maybe cleanup the replacement logic.
    switch ($RepositoryName) {
        "vscode-powershell" {
            $d = "Develop PowerShell scripts in Visual Studio Code!"
            if ($Version.PreReleaseLabel) {
                $name = "powershell-preview"
                $displayName = "PowerShell Preview"
                $preview = "true"
                $description = "(Preview) $d"
            } else {
                $name = "powershell"
                $displayName = "PowerShell"
                $preview = "false"
                $description = $d
            }
            $path = "package.json"
            $f = Get-Content -Path $path
            # NOTE: The prefix regex match two spaces exactly to avoid matching
            # nested objects in the file.
            $f = $f -replace '^(?<prefix>  "name":\s+")(.+)(?<suffix>",)$', "`${prefix}${name}`${suffix}"
            $f = $f -replace '^(?<prefix>  "displayName":\s+")(.+)(?<suffix>",)$', "`${prefix}${displayName}`${suffix}"
            $f = $f -replace '^(?<prefix>  "version":\s+")(.+)(?<suffix>",)$', "`${prefix}${v}`${suffix}"
            $f = $f -replace '^(?<prefix>  "preview":\s+)(.+)(?<suffix>,)$', "`${prefix}${preview}`${suffix}"
            $f = $f -replace '^(?<prefix>  "description":\s+")(.+)(?<suffix>",)$', "`${prefix}${description}`${suffix}"
            $f | Set-Content -Path $path
            git add $path
        }
        "PowerShellEditorServices" {
            $path = "PowerShellEditorServices.Common.props"
            $f = Get-Content -Path $path
            $f = $f -replace '^(?<prefix>\s+<VersionPrefix>)(.+)(?<suffix></VersionPrefix>)$', "`${prefix}${v}`${suffix}"
            $f = $f -replace '^(?<prefix>\s+<VersionSuffix>)(.*)(?<suffix></VersionSuffix>)$', "`${prefix}$($Version.PreReleaseLabel)`${suffix}"
            $f | Set-Content -Path $path
            git add $path

            $path = "module/PowerShellEditorServices/PowerShellEditorServices.psd1"
            $f = Get-Content -Path $path
            $f = $f -replace "^(?<prefix>ModuleVersion = ')(.+)(?<suffix>')`$", "`${prefix}${v}`${suffix}"
            $f | Set-Content -Path $path
            git add $path
        }
    }

    if ($PSCmdlet.ShouldProcess("$RepositoryName/v$Version", "git commit")) {
        git commit -m "Bump version to v$Version"
    }

    if ($PSCmdlet.ShouldProcess("$RepositoryName/v$Version", "git tag")) {
        git tag "v$Version"
    }

    Pop-Location
}

<#
.SYNOPSIS
  Creates a new draft GitHub release from the updated changelog.
.DESCRIPTION
  Requires that the changelog has been updated first as it pulls the release
  content and new version number from it.
#>
function New-DraftRelease {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet([RepoNames])]
        [string]$RepositoryName
    )
    # TODO: Abstract this to return version components and reuse in `Update-Version`.
    $Changelog = (Get-NewChangelog -RepositoryName $RepositoryName) -join "`n"
    $Version = if ($Changelog -match '## (?<version>v\S+)') {
        $Matches.version
    } else { Write-Error "Couldn't find version from changelog!" }
    $ReleaseParams = @{
        Draft      = $true
        Tag        = $Version
        Name       = $Version
        Body       = $ChangeLog
        PreRelease = $Version -match '-preview'
        # TODO: Pass -WhatIf and -Confirm parameters correctly.
    }
    Get-GitHubRepository -OwnerName PowerShell -RepositoryName $RepositoryName |
        New-GitHubRelease @ReleaseParams
}

Export-ModuleMember -Function Update-Changelog, Update-Version, New-DraftRelease
