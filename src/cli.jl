# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

"""
    ZenodoDeposits.CLI

The command-line front end used by `bin/zenodo-deposit`.
"""
module CLI

using ..ZenodoDeposits: build_bundle, write_checksums!, open_journal, deposit!, publish!, status, journal_state,
                        DepositError, RemoteError, MANIFEST, Client

const USAGE = """
usage: zenodo-deposit <dir> --metadata <m.json> [--sandbox|--production]
                      [--journal <statedir>] [--publish [--yes]]

Uploads every file in <dir> to a Zenodo draft (sandbox by default) and
verifies it. With --publish, then publishes it and prints the DOI; this is
irreversible and asks for confirmation unless --yes is given. Re-running
resumes from the journal (default: <dir>.zenodo-journal) and never creates a
second deposition or publishes twice.

The token is read from ZENODO_SANDBOX_TOKEN / ZENODO_TOKEN or ~/.netrc.

Exit codes: 0 ok, 1 error, 2 usage, 3 outcome unknown (a create or publish
may have reached Zenodo; re-run to reconcile, it never re-sends).
"""

"""
    parse_args(args) -> NamedTuple or String

Parse command-line arguments; returns an error message string on misuse.
"""
function parse_args(args::Vector{String})
    dir = nothing; metadata = nothing; journal = nothing
    env = :sandbox; envs = 0; publish = false; yes = false
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("--metadata", "--journal")
            i == length(args) && return "$a needs a value"
            a == "--metadata" ? (metadata = args[i+1]) : (journal = args[i+1])
            i += 2
            continue
        elseif a == "--sandbox"
            env = :sandbox; envs += 1
        elseif a == "--production"
            env = :production; envs += 1
        elseif a == "--publish"
            publish = true
        elseif a == "--yes"
            yes = true
        elseif a in ("-h", "--help")
            return "help"
        elseif startswith(a, "-")
            return "unknown option $a"
        elseif isnothing(dir)
            dir = a
        else
            return "unexpected argument $a"
        end
        i += 1
    end
    isnothing(dir) && return "missing <dir>"
    isnothing(metadata) && return "missing --metadata"
    envs > 1 && return "give only one of --sandbox and --production"
    yes && !publish && return "--yes only makes sense with --publish"
    journal = something(journal, rstrip(abspath(dir), '/') * ".zenodo-journal")
    return (; dir, metadata, journal, env, publish, yes)
end

"""
    main(args=ARGS; stdin, stdout, stderr, environ=ENV, client=nothing) -> Int

Run the command line and return the exit code. Errors are printed as their
sanitised message; no token is ever printed.
"""
function main(args::Vector{String}=ARGS; stdin::IO=Base.stdin, stdout::IO=Base.stdout,
              stderr::IO=Base.stderr, environ=ENV, client=nothing)
    opts = parse_args(args)
    if opts isa String
        opts == "help" && (print(stdout, USAGE); return 0)
        println(stderr, "zenodo-deposit: ", opts)
        print(stderr, USAGE)
        return 2
    end
    try
        bundle = build_bundle(opts.dir; metadata=opts.metadata)
        any(f -> f.name == MANIFEST, bundle.files) || (bundle = write_checksums!(bundle))
        journal = open_journal(opts.journal)
        c = isnothing(client) ? Client(opts.env; environ) : client
        # A publish that may already have been sent is resumed by publish!, which
        # only checks; deposit! refuses that state so a plain re-run cannot hide it.
        result = opts.publish && journal_state(journal) == :publish_uncertain ?
            status(journal) : deposit!(journal, bundle; env=opts.env, client=c)
        println(stdout, "state: ", result["state"])
        println(stdout, "environment: ", result["environment"])
        println(stdout, "deposition: ", result["deposition_id"])
        println(stdout, "reserved DOI: ", result["reserved_doi"])
        println(stdout, "journal: ", opts.journal)
        opts.publish || return 0
        if !opts.yes
            if !(stdin isa Base.TTY)
                println(stderr, "zenodo-deposit: refusing to publish without --yes when not attached to a terminal.")
                return 1
            end
            print(stdout, "Publish $(result["reserved_doi"]) on $(opts.env)? This is permanent. Type 'publish' to continue: ")
            strip(readline(stdin)) == "publish" || (println(stderr, "zenodo-deposit: not published."); return 1)
        end
        doi = publish!(journal; confirm=true, client=c)
        println(stdout, "published DOI: ", doi)
        println(stdout, "record: ", status(journal)["record_url"])
        return 0
    catch e
        if e isa DepositError || e isa RemoteError
            println(stderr, "zenodo-deposit: ", sprint(showerror, e))
            uncertain = (e isa RemoteError && e.ambiguous) ||
                e.code in ("publication_pending", "publication_uncertain", "publish_uncertain", "create_uncertain")
            return uncertain ? 3 : 1
        end
        println(stderr, "zenodo-deposit: unexpected ", nameof(typeof(e)), "; see the journal and retry.")
        return 1
    end
end

end # module CLI
