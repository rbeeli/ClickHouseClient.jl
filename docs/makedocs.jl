using Pkg

const DOCS_ROOT = @__DIR__
const PROJECT_ROOT = normpath(joinpath(DOCS_ROOT, ".."))

cd(DOCS_ROOT)
Pkg.activate(DOCS_ROOT)
Pkg.develop(; path=PROJECT_ROOT)
Pkg.resolve()
Pkg.instantiate()

# Keep wide table output readable in rendered examples.
ENV["COLUMNS"] = "160"
ENV["LINES"] = "80"

using Documenter: Documenter
using DocumenterVitepress
using Literate
using ClickHouseClient

const DOCS_REPO = "github.com/rbeeli/ClickHouseClient.jl"
const DEPLOY_REPO = "github.com/rbeeli/ClickHouseClient.jl.git"

const EXAMPLES_ROOT = joinpath(DOCS_ROOT, "src", "examples")
const GENERATED_EXAMPLES_ROOT = joinpath(EXAMPLES_ROOT, "gen")

rm(GENERATED_EXAMPLES_ROOT; recursive=true, force=true)
mkpath(GENERATED_EXAMPLES_ROOT)

function gen_markdown(path)
    Literate.markdown(
        joinpath(EXAMPLES_ROOT, path),
        GENERATED_EXAMPLES_ROOT;
        credit=false,
        documenter=false,
    )
end

gen_markdown("1_ingest_events.jl")
gen_markdown("2_stream_query_results.jl")
gen_markdown("3_datetime64_precision.jl")
gen_markdown("4_batch_loader.jl")

function deploy_decision()
    decision = Documenter.deploy_folder(
        Documenter.auto_detect_deploy_system();
        repo=DOCS_REPO,
        devbranch="main",
        devurl="dev",
        push_preview=true,
    )

    if decision.all_ok && !decision.is_preview && decision.subfolder == "dev"
        return Documenter.DeployDecision(;
            all_ok=decision.all_ok,
            branch=decision.branch,
            is_preview=decision.is_preview,
            repo=decision.repo,
            subfolder="",
        )
    end

    return decision
end

deployment = deploy_decision()

Documenter.makedocs(
    sitename="ClickHouseClient.jl",
    format=DocumenterVitepress.MarkdownVitepress(;
        repo=DOCS_REPO,
        devurl="dev",
        devbranch="main",
        description="A native ClickHouse TCP client for Julia.",
        deploy_decision=deployment,
        assets=["assets/styles.css"],
    ),
    pages=[
        "Home" => "index.md",
        "Getting started" => "getting_started.md",
        "Basic setup" => "basic_setup.md",
        "Connections" => "connections.md",
        "Inserts and queries" => "inserts_and_queries.md",
        "DataFrames integration" => "dataframes.md",
        "Type mapping" => "type_mapping.md",
        "Date/time and time zones" => "datetime_timezones.md",
        "Pitfalls and gotchas" => "pitfalls.md",
        "Examples" => [
            "Ingest application events" => "examples/gen/1_ingest_events.md",
            "Stream query results" => "examples/gen/2_stream_query_results.md",
            "DateTime64 precision" => "examples/gen/3_datetime64_precision.md",
            "Batch loader" => "examples/gen/4_batch_loader.md",
        ],
        "API index" => "api_index.md",
        "Glossary" => "glossary.md",
    ],
    warnonly=get(ENV, "CI", "false") != "true",
    pagesonly=true,
)

Documenter.deploydocs(
    repo=DEPLOY_REPO,
    target=joinpath("build", "1"),
    versions=nothing,
    push_preview=true,
    devbranch="main",
)
