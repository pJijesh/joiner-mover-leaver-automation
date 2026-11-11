$script:JmlTransliteration = @{
    a = 'àáâãäåāăą'; c = 'çćĉċč'; d = 'ďđð'; e = 'èéêëēĕėęě'; g = 'ĝğġģ'; h = 'ĥħ'
    i = 'ìíîïĩīĭįı'; j = 'ĵ'; k = 'ķ'; l = 'ĺļľŀł'; n = 'ñńņň'; o = 'òóôõöøōŏő'
    r = 'ŕŗř'; s = 'śŝşš'; t = 'ţťŧþ'; u = 'ùúûüũūŭůűų'; w = 'ŵ'; y = 'ýÿŷ'; z = 'źżž'
}

function ConvertTo-JmlSlug {
    <#
    .SYNOPSIS
        Turns a personal name into a lower-case, ASCII-only token that is safe in a user principal name.
    .DESCRIPTION
        Accents are removed (Zoë becomes zoe), apostrophes are dropped (O'Neil becomes oneil),
        spaces become hyphens, and anything else outside a-z, 0-9, hyphen is removed.
        A built-in table covers Latin letters so the result does not depend on the ICU
        libraries available on the machine running the automation.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    $text = $Name.Trim().ToLowerInvariant()
    try { $text = $text.Normalize([System.Text.NormalizationForm]::FormD) }
    catch { Write-Verbose 'Unicode normalisation unavailable; using the built-in table only.' }

    $builder = [System.Text.StringBuilder]::new()
    foreach ($char in $text.ToCharArray()) {
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($char)
        if ($category -eq [System.Globalization.UnicodeCategory]::NonSpacingMark) { continue }
        if ($char -eq [char]0xDF) { [void]$builder.Append('ss'); continue }
        if ($char -eq [char]0xE6) { [void]$builder.Append('ae'); continue }
        if ($char -eq [char]0x153) { [void]$builder.Append('oe'); continue }
        $replacement = $null
        if ([int]$char -gt 127) {
            foreach ($key in $script:JmlTransliteration.Keys) {
                if ($script:JmlTransliteration[$key].Contains([string]$char)) { $replacement = $key; break }
            }
        }
        [void]$builder.Append($(if ($replacement) { $replacement } else { $char }))
    }
    $slug = $builder.ToString()
    $slug = $slug -replace "['’]", ''
    $slug = $slug -replace '\s+', '-'
    $slug = $slug -replace '[^a-z0-9\-]', ''
    $slug.Trim('-')
}
