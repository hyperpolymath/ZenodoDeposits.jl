# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Validation of Zenodo deposition-v1 metadata, done locally before any request.

const UPLOAD_TYPES = Set(["publication", "poster", "presentation", "dataset", "image", "video",
                          "software", "lesson", "physicalobject", "other"])
const PUBLICATION_TYPES = Set(["annotationcollection", "book", "section", "conferencepaper",
    "datamanagementplan", "article", "patent", "preprint", "deliverable", "milestone", "proposal",
    "report", "softwaredocumentation", "taxonomictreatment", "technicalnote", "thesis",
    "workingpaper", "other"])
const IMAGE_TYPES = Set(["figure", "plot", "drawing", "diagram", "photo", "other"])
const ACCESS_RIGHTS = Set(["open", "embargoed", "restricted", "closed"])

# Fields this package interprets. Any other field in OPTIONAL_FIELDS is passed
# to Zenodo unchanged after a structural check. Everything else is refused, in
# particular `doi`, `prereserve_doi` and anything that could carry a token.
const CHECKED_FIELDS = Set(["title", "upload_type", "publication_type", "image_type", "description",
    "creators", "access_right", "license", "embargo_date", "access_conditions", "publication_date",
    "version", "keywords", "related_identifiers", "contributors", "notes", "language"])
const OPTIONAL_FIELDS = Set(["references", "communities", "grants", "subjects", "locations", "dates",
    "method", "journal_title", "journal_volume", "journal_issue", "journal_pages",
    "conference_title", "conference_acronym", "conference_dates", "conference_place",
    "conference_url", "conference_session", "conference_session_part", "imprint_publisher",
    "imprint_isbn", "imprint_place", "partof_title", "partof_pages", "thesis_supervisors",
    "thesis_university"])

"""
    invalid(message)

Throw a [`DepositError`](@ref) with code `invalid_metadata`.
"""
invalid(message) = fail("invalid_metadata", message)

"""
    _text(value, field; max_length=500, optional=false) -> String

Return `value` stripped, refusing non-strings, empty text (unless `optional`),
over-long text and control characters other than newline and tab.
"""
function _text(value, field; max_length::Int=500, optional::Bool=false)
    value isa AbstractString || invalid("$field must be text.")
    text = String(strip(value))
    (!optional && isempty(text)) && invalid("$field must not be empty.")
    length(text) <= max_length || invalid("$field is longer than $max_length characters.")
    any(c -> iscntrl(c) && c != '\n' && c != '\t', text) && invalid("$field contains control characters.")
    return text
end

"""
    _orcid(value) -> String

Validate an ORCID iD in `0000-0000-0000-000X` form, including its ISO 7064
MOD 11-2 check digit.
"""
function _orcid(value)
    text = _text(value, "creator orcid"; max_length=19)
    occursin(r"^[0-9]{4}-[0-9]{4}-[0-9]{4}-[0-9]{3}[0-9X]$", text) ||
        invalid("ORCID must use the 0000-0000-0000-000X form.")
    digits = replace(text, "-" => "")
    total = 0
    for d in digits[1:15]
        total = (total + (Int(d) - Int('0'))) * 2
    end
    check = (12 - total % 11) % 11
    string(last(digits)) == (check == 10 ? "X" : string(check)) || invalid("ORCID checksum is invalid.")
    return text
end

"""
    _date(value, field; not_after=nothing) -> String

Validate a real calendar date in `YYYY-MM-DD` form, optionally no later than
`not_after`.
"""
function _date(value, field; not_after::Union{Date,Nothing}=nothing)
    text = _text(value, field; max_length=10)
    date = try
        Date(text, dateformat"yyyy-mm-dd")
    catch
        invalid("$field must be YYYY-MM-DD.")
    end
    string(date) == text || invalid("$field must be a real date in YYYY-MM-DD form.")
    isnothing(not_after) || date <= not_after || invalid("$field must not be in the future.")
    return text
end

"""
    _people(value, field; contributors=false) -> Vector{Dict{String,Any}}

Validate a creators (or contributors) list: 1–1000 objects, each with a real
`name` and optional `affiliation`, `orcid` and `gnd` (plus `type` for
contributors).
"""
function _people(value, field; contributors::Bool=false)
    value isa AbstractVector && 1 <= length(value) <= 1000 || invalid("Provide 1–1000 $field.")
    allowed = contributors ? ("name", "affiliation", "orcid", "gnd", "type") : ("name", "affiliation", "orcid", "gnd")
    people = Dict{String,Any}[]
    for person in value
        person isa AbstractDict || invalid("Each entry of $field must be an object.")
        all(k -> string(k) in allowed, keys(person)) || invalid("Unknown field in $field; allowed: $(join(allowed, ", ")).")
        p = Dict{String,Any}(string(k) => v for (k, v) in person)
        name = _text(get(p, "name", nothing), "$field name"; max_length=250)
        lowercase(name) in ("anonymous", "unknown", "test", "your name", "todo") &&
            invalid("Replace placeholder names in $field with the real people.")
        record = Dict{String,Any}("name" => name)
        haskey(p, "affiliation") && (record["affiliation"] = _text(p["affiliation"], "$field affiliation"; optional=true))
        haskey(p, "orcid") && (record["orcid"] = _orcid(p["orcid"]))
        haskey(p, "gnd") && (record["gnd"] = _text(p["gnd"], "$field gnd"; max_length=20))
        contributors && (record["type"] = _text(get(p, "type", nothing), "contributor type"; max_length=50))
        push!(people, record)
    end
    return people
end

"""
    _json_value(value, field)

Structurally check a pass-through value: only strings, numbers, booleans,
vectors and string-keyed objects of those, nested at most 6 deep.
"""
function _json_value(value, field, depth::Int=0)
    depth <= 6 || invalid("$field is nested too deeply.")
    if value isa AbstractString
        _text(value, field; max_length=10000, optional=true)
    elseif value isa AbstractDict
        for (k, v) in value
            _json_value(v, field, depth + 1)
            k isa Union{AbstractString,Symbol} || invalid("$field has a non-text key.")
        end
    elseif value isa AbstractVector
        foreach(v -> _json_value(v, field, depth + 1), value)
    elseif !(value isa Union{Real,Bool})
        invalid("$field contains an unsupported value.")
    end
    return value
end

"""
    validate_metadata(input; today=Dates.today()) -> Dict{String,Any}

Validate Zenodo deposition metadata before any network request and return a
normalised copy.

Required: `title`, `upload_type`, `description` and `creators`, plus
`license` whenever `access_right` is `open` (the default) or `embargoed`.
Also required: `publication_type` for publications, `image_type` for images,
`embargo_date` for embargoed records, and `access_conditions` for restricted
records. Unknown fields are refused, and so are `doi` and `prereserve_doi`:
the DOI is always reserved by Zenodo, never supplied by the caller.
"""
function validate_metadata(input::AbstractDict; today::Date=Dates.today())
    m = Dict{String,Any}(string(k) => v for (k, v) in input)
    for key in keys(m)
        key in CHECKED_FIELDS || key in OPTIONAL_FIELDS ||
            invalid("Unknown or forbidden metadata field `$key`. DOIs, tokens and API URLs are never accepted in metadata.")
    end
    out = Dict{String,Any}()
    out["title"] = _text(get(m, "title", nothing), "title"; max_length=1000)
    upload_type = get(m, "upload_type", nothing)
    upload_type in UPLOAD_TYPES || invalid("upload_type must be one of: $(join(sort!(collect(UPLOAD_TYPES)), ", ")).")
    out["upload_type"] = upload_type
    if upload_type == "publication"
        get(m, "publication_type", nothing) in PUBLICATION_TYPES ||
            invalid("publication_type is required for publications and must be a Zenodo publication type.")
        out["publication_type"] = m["publication_type"]
    elseif haskey(m, "publication_type")
        invalid("publication_type is only valid when upload_type is publication.")
    end
    if upload_type == "image"
        get(m, "image_type", nothing) in IMAGE_TYPES ||
            invalid("image_type is required for images and must be a Zenodo image type.")
        out["image_type"] = m["image_type"]
    elseif haskey(m, "image_type")
        invalid("image_type is only valid when upload_type is image.")
    end
    out["description"] = _text(get(m, "description", nothing), "description"; max_length=100_000)
    out["creators"] = _people(get(m, "creators", nothing), "creators")
    access = get(m, "access_right", "open")
    access in ACCESS_RIGHTS || invalid("access_right must be one of: open, embargoed, restricted, closed.")
    out["access_right"] = access
    if access in ("open", "embargoed") || haskey(m, "license")
        license = _text(get(m, "license", nothing), "license"; max_length=100)
        occursin(r"^[A-Za-z0-9][A-Za-z0-9.+_-]*$", license) ||
            invalid("license must be a Zenodo licence identifier such as cc-by-4.0 or mit.")
        out["license"] = lowercase(license)
    end
    if access == "embargoed"
        out["embargo_date"] = _date(get(m, "embargo_date", nothing), "embargo_date")
        Date(out["embargo_date"]) > today || invalid("embargo_date must be in the future.")
    elseif haskey(m, "embargo_date")
        invalid("embargo_date is only valid for embargoed records.")
    end
    if access == "restricted"
        out["access_conditions"] = _text(get(m, "access_conditions", nothing), "access_conditions"; max_length=10_000)
    elseif haskey(m, "access_conditions")
        invalid("access_conditions is only valid for restricted records.")
    end
    haskey(m, "publication_date") && (out["publication_date"] = _date(m["publication_date"], "publication_date"; not_after=today))
    haskey(m, "version") && (out["version"] = _text(m["version"], "version"; max_length=100))
    haskey(m, "language") && (out["language"] = _text(m["language"], "language"; max_length=3))
    haskey(m, "notes") && (out["notes"] = _text(m["notes"], "notes"; max_length=10_000))
    if haskey(m, "keywords")
        m["keywords"] isa AbstractVector || invalid("keywords must be a list of text.")
        out["keywords"] = [_text(k, "keyword"; max_length=250) for k in m["keywords"]]
    end
    haskey(m, "contributors") && (out["contributors"] = _people(m["contributors"], "contributors"; contributors=true))
    if haskey(m, "related_identifiers")
        m["related_identifiers"] isa AbstractVector || invalid("related_identifiers must be a list.")
        out["related_identifiers"] = map(m["related_identifiers"]) do r
            r isa AbstractDict || invalid("Each related identifier must be an object.")
            rr = Dict{String,Any}(string(k) => v for (k, v) in r)
            all(k -> k in ("identifier", "relation", "resource_type", "scheme"), keys(rr)) ||
                invalid("Unknown field in related_identifiers.")
            item = Dict{String,Any}("identifier" => _text(get(rr, "identifier", nothing), "related identifier"; max_length=2048),
                                    "relation" => _text(get(rr, "relation", nothing), "related identifier relation"; max_length=100))
            for k in ("resource_type", "scheme")
                haskey(rr, k) && (item[k] = _text(rr[k], "related identifier $k"; max_length=100))
            end
            item
        end
    end
    for key in OPTIONAL_FIELDS
        haskey(m, key) && (out[key] = _json_value(m[key], key))
    end
    return out
end

"""
    identity_fields(metadata) -> Dict{String,Any}

The fields compared with a remote deposition to decide that it is the one
this journal created: title, upload type, creator names, access right,
licence, version and publication date. Zenodo may normalise HTML and add
fields elsewhere, so the comparison is deliberately limited to these.
"""
function identity_fields(metadata::AbstractDict)
    out = Dict{String,Any}("title" => strip(string(get(metadata, "title", ""))),
        "upload_type" => get(metadata, "upload_type", nothing),
        "access_right" => get(metadata, "access_right", nothing),
        "creators" => [strip(string(get(c, "name", ""))) for c in get(metadata, "creators", Any[]) if c isa AbstractDict])
    license = get(metadata, "license", nothing)
    license isa AbstractDict && (license = get(license, "id", nothing))
    out["license"] = license isa AbstractString ? lowercase(license) : nothing
    for key in ("version", "publication_date")
        value = get(metadata, key, nothing)
        out[key] = value isa AbstractString ? strip(value) : nothing
    end
    return out
end
